//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "hardhat/console.sol";
import { PredictionMarketToken } from "./PredictionMarketToken.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract PredictionMarket is Ownable {
    /////////////////
    /// Errors //////
    /////////////////

    error PredictionMarket__MustProvideETHForInitialLiquidity();
    error PredictionMarket__InvalidProbability();
    error PredictionMarket__PredictionAlreadyReported();
    error PredictionMarket__OnlyOracleCanReport();
    error PredictionMarket__OwnerCannotCall();
    error PredictionMarket__PredictionNotReported();
    error PredictionMarket__InsufficientWinningTokens();
    error PredictionMarket__AmountMustBeGreaterThanZero();
    error PredictionMarket__MustSendExactETHAmount();
    error PredictionMarket__InsufficientTokenReserve(Outcome _outcome, uint256 _amountToken);
    error PredictionMarket__TokenTransferFailed();
    error PredictionMarket__ETHTransferFailed();
    error PredictionMarket__InsufficientBalance(uint256 _tradingAmount, uint256 _userBalance);
    error PredictionMarket__InsufficientAllowance(uint256 _tradingAmount, uint256 _allowance);
    error PredictionMarket__InsufficientLiquidity();
    error PredictionMarket__InvalidPercentageToLock();

    //////////////////////////
    /// State Variables //////
    //////////////////////////

    enum Outcome {
        YES,
        NO
    }

    uint256 private constant PRECISION = 1e18;

    /// Checkpoint 2 ///
    address public immutable i_oracle;
    uint256 public immutable i_initialTokenValue;
    uint256 public immutable i_initialYesProbability;
    uint256 public immutable i_percentageLocked;

    string public s_question;
    uint256 public s_ethCollateral;
    uint256 public s_lpTradingRevenue;
    /// Checkpoint 3 ///
    PredictionMarketToken public immutable i_yesToken;
    PredictionMarketToken public immutable i_noToken;

    /// Checkpoint 5 ///
    PredictionMarketToken public s_winningToken;
    // ⚠️要设置为public
    bool public s_isReported;

    /////////////////////////
    /// Events //////
    /////////////////////////

    event TokensPurchased(address indexed buyer, Outcome outcome, uint256 amount, uint256 ethAmount);
    event TokensSold(address indexed seller, Outcome outcome, uint256 amount, uint256 ethAmount);
    event WinningTokensRedeemed(address indexed redeemer, uint256 amount, uint256 ethAmount);
    event MarketReported(address indexed oracle, Outcome winningOutcome, address winningToken);
    event MarketResolved(address indexed resolver, uint256 totalEthToSend);
    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 tokensAmount);
    event LiquidityRemoved(address indexed provider, uint256 ethAmount, uint256 tokensAmount);

    /////////////////
    /// Modifiers ///
    /////////////////

    /// Checkpoint 5 ///
    modifier predictionNotReported() {
        if (s_isReported) {
            revert PredictionMarket__PredictionAlreadyReported();
        }
        _;
    }

    /// Checkpoint 6 ///
    modifier predictionAlreadyReported() {
        if (!s_isReported) {
            revert PredictionMarket__PredictionNotReported();
        }
        _;
    }

    /// Checkpoint 8 ///

    //////////////////
    ////Constructor///
    //////////////////

    constructor(
        address _liquidityProvider,
        address _oracle,
        string memory _question,
        uint256 _initialTokenValue,
        uint8 _initialYesProbability,
        uint8 _percentageToLock
    ) payable Ownable(_liquidityProvider) {
        /// Checkpoint 2 ////
        // 2.1 初始化oracle地址
        i_oracle = _oracle;
        // 2.2 初始化question
        s_question = _question;
        // 2.3 初始化TokenValue，部署脚本中值=0.01
        i_initialTokenValue = _initialTokenValue;
        // 2.4 初始化s_ethCollateral，部署脚本中值=1
        if (msg.value == 0) {
            revert PredictionMarket__MustProvideETHForInitialLiquidity();
        }
        s_ethCollateral = msg.value;
        // 2.5 初始化YesProbability，并限定在0~100之间
        if (_initialYesProbability == 0 || _initialYesProbability >= 100) {
            revert PredictionMarket__InvalidProbability();
        }
        i_initialYesProbability = _initialYesProbability;
        // 2.6 初始化percentageToLock，并限定在0~100之间
        if (_percentageToLock == 0 || _percentageToLock >= 100) {
            revert PredictionMarket__InvalidPercentageToLock();
        }
        i_percentageLocked = _percentageToLock;
        /// Checkpoint 3 ////
        // 3.1 计算用户初始化总token个数= 1 / 0.01 * 1e18 = 100
        uint256 initialTokenAmount = (msg.value * PRECISION) / _initialTokenValue;
        // 3.2 初始化Y币
        i_yesToken = new PredictionMarketToken("Yes", "Y", msg.sender, initialTokenAmount);
        // 3.3 初始化N币
        i_noToken = new PredictionMarketToken("No", "N", msg.sender, initialTokenAmount);
        // 3.4 计算Y币和N币的锁定池,公式(yesToken + noToken) * probability/100 * lock/100
        uint256 initialAmountLocked = (initialTokenAmount * 2 * _percentageToLock) / 100;
        uint256 initialYesAmountLocked = (_initialYesProbability * initialAmountLocked) / 100;
        uint256 initialNoAmountLocked = ((100 - _initialYesProbability) * initialAmountLocked) / 100;
        // 3.5 把锁定的Y币和N币发生给部署的人
        bool sentY = i_yesToken.transfer(msg.sender, initialYesAmountLocked);
        bool sentN = i_noToken.transfer(msg.sender, initialNoAmountLocked);
        // 3.6 确保转移成功
        if (!sentY || !sentN) {
            revert PredictionMarket__TokenTransferFailed();
        }
    }

    /////////////////
    /// Functions ///
    /////////////////

    /**
     * @notice Add liquidity to the prediction market and mint tokens
     * @dev Only the owner can add liquidity and only if the prediction is not reported
     */
    function addLiquidity() external payable onlyOwner predictionNotReported {
        //// Checkpoint 4 ////
        // 1.校验输入的eth
        if (msg.value == 0) {
            revert PredictionMarket__MustSendExactETHAmount();
        }
        // 2.计算要mint的token数量
        uint256 addTokenAmount = (msg.value * PRECISION) / i_initialTokenValue;
        // 3.给合约铸造Y币和N币
        i_yesToken.mint(address(this), addTokenAmount);
        i_noToken.mint(address(this), addTokenAmount);
        // 4.更新eth的抵押总量
        s_ethCollateral += msg.value;

        // 5.发送流动性增加事件
        emit LiquidityAdded(msg.sender, msg.value, addTokenAmount);
    }

    /**
     * @notice Remove liquidity from the prediction market and burn respective tokens, if you remove liquidity before prediction ends you got no share of lpReserve
     * @dev Only the owner can remove liquidity and only if the prediction is not reported
     * @param _ethToWithdraw Amount of ETH to withdraw from liquidity pool
     */
    function removeLiquidity(uint256 _ethToWithdraw) external onlyOwner predictionNotReported {
        //// Checkpoint 4 ////
        // 1.计算取回eth对应销毁的token数量
        uint256 burnTokensAmount = (_ethToWithdraw * PRECISION) / i_initialTokenValue;
        // 2.校验是否有足够的Y币和N币进行销毁
        if (burnTokensAmount > i_yesToken.balanceOf(address(this))) {
            revert PredictionMarket__InsufficientTokenReserve(Outcome.YES, burnTokensAmount);
        }
        if (burnTokensAmount > i_noToken.balanceOf(address(this))) {
            revert PredictionMarket__InsufficientTokenReserve(Outcome.NO, burnTokensAmount);
        }
        // 3.销毁Y币和N币数量
        i_yesToken.burn(address(this), burnTokensAmount);
        i_noToken.burn(address(this), burnTokensAmount);
        // 4.转账给owner
        (bool sent, ) = msg.sender.call{ value: _ethToWithdraw }("");
        if (!sent) {
            revert PredictionMarket__ETHTransferFailed();
        }
        // 5.更新eth抵押总量
        s_ethCollateral -= _ethToWithdraw;

        // 6.发生流动性减少事件
        emit LiquidityRemoved(msg.sender, _ethToWithdraw, burnTokensAmount);
    }

    /**
     * @notice Report the winning outcome for the prediction
     * @dev Only the oracle can report the winning outcome and only if the prediction is not reported
     * @param _winningOutcome The winning outcome (YES or NO)
     */
    function report(Outcome _winningOutcome) external predictionNotReported {
        //// Checkpoint 5 ////
        // 1.判断执行者是否是oracle
        if (msg.sender != i_oracle) {
            revert PredictionMarket__OnlyOracleCanReport();
        }
        // 2.设置获胜结果
        s_winningToken = _winningOutcome == Outcome.YES ? i_yesToken : i_noToken;
        // 3.将s_isReported置为true
        s_isReported = true;

        // 4.触发report事件
        emit MarketReported(msg.sender, _winningOutcome, address(s_winningToken));
    }

    /**
     * @notice Owner of contract can redeem winning tokens held by the contract after prediction is resolved and get ETH from the contract including LP revenue and collateral back
     * @dev Only callable by the owner and only if the prediction is resolved
     * @return ethRedeemed The amount of ETH redeemed
     */
    function resolveMarketAndWithdraw() external onlyOwner predictionAlreadyReported returns (uint256 ethRedeemed) {
        /// Checkpoint 6 ////
        // 1.校验获胜的token数量
        uint256 winningTokensAmount = s_winningToken.balanceOf(address(this));
        if (winningTokensAmount > 0) {
            // 2.计算ethRedeemed = 获胜的token数(1e18) * token单价(1e18) / 1e18
            // ⚠️1e18的精度处理
            ethRedeemed = (winningTokensAmount * i_initialTokenValue) / PRECISION;
            // 2.1 限制ethRedeemed不能大于抵押的eth数
            ethRedeemed = ethRedeemed > s_ethCollateral ? s_ethCollateral : ethRedeemed;
            // 2.2 更新owner的eth抵押
            s_ethCollateral -= ethRedeemed;
        }
        // 3.计算owner获取eth的总数 = ethRedeemed + s_lpTradingRevenue
        uint256 totalEthtoGet = ethRedeemed + s_lpTradingRevenue;
        // 4.获取前将token销毁
        s_winningToken.burn(address(this), winningTokensAmount);
        // 5.获取eth
        (bool sent, ) = msg.sender.call{ value: totalEthtoGet }("");
        if (!sent) {
            revert PredictionMarket__ETHTransferFailed();
        }

        // 6.发送WinningTokensRedeemed事件
        emit MarketResolved(msg.sender, totalEthtoGet);

        return ethRedeemed;
    }

    /**
     * @notice Buy prediction outcome tokens with ETH, need to call priceInETH function first to get right amount of tokens to buy
     * @param _outcome The possible outcome (YES or NO) to buy tokens for
     * @param _amountTokenToBuy Amount of tokens to purchase
     */
    function buyTokensWithETH(Outcome _outcome, uint256 _amountTokenToBuy) external payable {
        /// Checkpoint 8 ////
    }

    /**
     * @notice Sell prediction outcome tokens for ETH, need to call priceInETH function first to get right amount of tokens to buy
     * @param _outcome The possible outcome (YES or NO) to sell tokens for
     * @param _tradingAmount The amount of tokens to sell
     */
    function sellTokensForEth(Outcome _outcome, uint256 _tradingAmount) external {
        /// Checkpoint 8 ////
    }

    /**
     * @notice Redeem winning tokens for ETH after prediction is resolved, winning tokens are burned and user receives ETH
     * @dev Only if the prediction is resolved
     * @param _amount The amount of winning tokens to redeem
     */
    function redeemWinningTokens(uint256 _amount) external {
        /// Checkpoint 9 ////
    }

    /**
     * @notice Calculate the total ETH price for buying tokens
     * @param _outcome The possible outcome (YES or NO) to buy tokens for
     * @param _tradingAmount The amount of tokens to buy
     * @return The total ETH price
     */
    function getBuyPriceInEth(Outcome _outcome, uint256 _tradingAmount) public view returns (uint256) {
        /// Checkpoint 7 ////
    }

    /**
     * @notice Calculate the total ETH price for selling tokens
     * @param _outcome The possible outcome (YES or NO) to sell tokens for
     * @param _tradingAmount The amount of tokens to sell
     * @return The total ETH price
     */
    function getSellPriceInEth(Outcome _outcome, uint256 _tradingAmount) public view returns (uint256) {
        /// Checkpoint 7 ////
    }

    /////////////////////////
    /// Helper Functions ///
    ////////////////////////

    /**
     * @dev Internal helper to calculate ETH price for both buying and selling
     * @param _outcome The possible outcome (YES or NO)
     * @param _tradingAmount The amount of tokens
     * @param _isSelling Whether this is a sell calculation
     */
    function _calculatePriceInEth(
        Outcome _outcome,
        uint256 _tradingAmount,
        bool _isSelling
    ) private view returns (uint256) {
        /// Checkpoint 7 ////
    }

    /**
     * @dev Internal helper to get the current reserves of the tokens
     * @param _outcome The possible outcome (YES or NO)
     * @return The current reserves of the tokens
     */
    function _getCurrentReserves(Outcome _outcome) private view returns (uint256, uint256) {
        /// Checkpoint 7 ////
    }

    /**
     * @dev Internal helper to calculate the probability of the tokens
     * @param tokensSold The number of tokens sold
     * @param totalSold The total number of tokens sold
     * @return The probability of the tokens
     */
    function _calculateProbability(uint256 tokensSold, uint256 totalSold) private pure returns (uint256) {
        /// Checkpoint 7 ////
    }

    /////////////////////////
    /// Getter Functions ///
    ////////////////////////

    /**
     * @notice Get the prediction details
     */
    function getPrediction()
        external
        view
        returns (
            string memory question,
            string memory outcome1,
            string memory outcome2,
            address oracle,
            uint256 initialTokenValue,
            uint256 yesTokenReserve,
            uint256 noTokenReserve,
            bool isReported,
            address yesToken,
            address noToken,
            address winningToken,
            uint256 ethCollateral,
            uint256 lpTradingRevenue,
            address predictionMarketOwner,
            uint256 initialProbability,
            uint256 percentageLocked
        )
    {
        /// Checkpoint 3 ////
        oracle = i_oracle;
        initialTokenValue = i_initialTokenValue;
        percentageLocked = i_percentageLocked;
        initialProbability = i_initialYesProbability;
        question = s_question;
        ethCollateral = s_ethCollateral;
        lpTradingRevenue = s_lpTradingRevenue;
        predictionMarketOwner = owner();
        yesToken = address(i_yesToken);
        noToken = address(i_noToken);
        outcome1 = i_yesToken.name();
        outcome2 = i_noToken.name();
        yesTokenReserve = i_yesToken.balanceOf(address(this));
        noTokenReserve = i_noToken.balanceOf(address(this));
        /// Checkpoint 5 ////
        isReported = s_isReported;
        winningToken = address(s_winningToken);
    }
}
