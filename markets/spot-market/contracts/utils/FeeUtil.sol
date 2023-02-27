//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import "../storage/SpotMarketFactory.sol";
import "../storage/FeeConfiguration.sol";
import "../storage/AsyncOrder.sol";
import "../utils/SynthUtil.sol";

import "hardhat/console.sol";

library FeeUtil {
    using SpotMarketFactory for SpotMarketFactory.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using DecimalMath for uint256;
    using DecimalMath for int256;

    /**
     * @dev Calculates fees then runs the fees through a fee collector before returning the computed data.
     */
    function processFees(
        uint128 marketId,
        address transactor,
        uint256 usdAmount,
        uint256 synthPrice,
        Transaction.Type transactionType
    ) internal returns (uint256 amountUsable, int256 totalFees, uint collectedFees) {
        (amountUsable, totalFees) = calculateFees(
            marketId,
            transactor,
            usdAmount,
            synthPrice,
            transactionType
        );

        collectedFees = collectFees(marketId, totalFees, transactor, transactionType);
    }

    /**
     * @dev Calculates fees for a given transaction type.
     */
    function calculateFees(
        uint128 marketId,
        address transactor,
        uint256 usdAmount,
        uint256 synthPrice,
        Transaction.Type transactionType
    ) internal returns (uint256 amountUsable, int256 feesCollected) {
        FeeConfiguration.Data storage feeConfiguration = FeeConfiguration.load(marketId);

        if (Transaction.isBuy(transactionType)) {
            (amountUsable, feesCollected) = calculateBuyFees(
                feeConfiguration,
                transactor,
                marketId,
                usdAmount,
                synthPrice,
                transactionType == Transaction.Type.ASYNC_BUY
            );
        } else if (Transaction.isSell(transactionType)) {
            (amountUsable, feesCollected) = calculateSellFees(
                feeConfiguration,
                transactor,
                marketId,
                usdAmount,
                synthPrice,
                transactionType == Transaction.Type.ASYNC_SELL
            );
        } else if (transactionType == Transaction.Type.WRAP) {
            (amountUsable, feesCollected) = calculateWrapFees(feeConfiguration, usdAmount);
        } else if (transactionType == Transaction.Type.UNWRAP) {
            (amountUsable, feesCollected) = calculateUnwrapFees(feeConfiguration, usdAmount);
        } else {
            amountUsable = usdAmount;
            feesCollected = 0;
        }
    }

    /**
     * @dev Calculates wrap fees based on the wrapFixedFee.
     */
    function calculateWrapFees(
        FeeConfiguration.Data storage feeConfiguration,
        uint256 amount
    ) internal view returns (uint amountUsable, int feesCollected) {
        (amountUsable, feesCollected) = _applyFees(amount, feeConfiguration.wrapFixedFee);
    }

    /**
     * @dev Calculates wrap fees based on the unwrapFixedFee.
     */
    function calculateUnwrapFees(
        FeeConfiguration.Data storage feeConfiguration,
        uint256 amount
    ) internal view returns (uint amountUsable, int feesCollected) {
        (amountUsable, feesCollected) = _applyFees(amount, feeConfiguration.unwrapFixedFee);
    }

    /**
     * @dev Calculates fees for a buy transaction.
     *
     * Fees are calculated as follows:
     *
     * 1. Utilization fee (bips):  The utilization fee is a fee that's applied based on the ratio of delegated collateral to total outstanding synth exposure.
     * 2. Skew fee (bips): The skew fee is a fee that's applied based on the ratio of outstanding synths to the skew scale.
     * 3. Fixed fee (bips): The fixed fee is a fee that's applied to every transaction.
     */
    function calculateBuyFees(
        FeeConfiguration.Data storage feeConfiguration,
        address transactor,
        uint128 marketId,
        uint256 amount,
        uint256 synthPrice,
        bool async
    ) internal returns (uint amountUsable, int calculatedFees) {
        uint utilizationFee = calculateUtilizationRateFee(
            feeConfiguration,
            marketId,
            amount,
            synthPrice
        );

        int skewFee = calculateSkewFee(
            feeConfiguration,
            marketId,
            amount,
            synthPrice,
            Transaction.Type.BUY
        );

        console.log("SKEW FEE");
        console.logInt(skewFee);

        uint fixedFee = _getFixedFee(feeConfiguration, transactor, async);

        int totalFees = utilizationFee.toInt() + skewFee + fixedFee.toInt();

        (amountUsable, calculatedFees) = _applyFees(amount, totalFees);
    }

    /**
     * @dev Calculates fees for a sell transaction.
     *
     * Fees are calculated as follows:
     *
     * 1. Skew fee (bips): The skew fee is a fee that's applied based on the ratio of outstanding synths to the skew scale.
     *    When a sell trade is executed, the skew fee is applied as a negative value to create incentive to bring market to equilibrium.
     * 3. Fixed fee (bips): The fixed fee is a fee that's applied to every transaction.
     */
    function calculateSellFees(
        FeeConfiguration.Data storage feeConfiguration,
        address transactor,
        uint128 marketId,
        uint256 amount,
        uint256 synthPrice,
        bool async
    ) internal returns (uint amountUsable, int feesCollected) {
        int skewFee = calculateSkewFee(
            feeConfiguration,
            marketId,
            amount,
            synthPrice,
            Transaction.Type.SELL
        );

        uint fixedFee = _getFixedFee(feeConfiguration, transactor, async);

        int totalFees = skewFee + fixedFee.toInt();

        (amountUsable, feesCollected) = _applyFees(amount, totalFees);
    }

    /**
     * @dev Calculates skew fee
     *
     * If no skewScale is set, then the fee is 0
     * The skew fee is determined based on the ratio of outstanding synth value to the skew scale value.
     * Example:
     *  Skew scale set to 1000 snxETH
     *  Before fill outstanding snxETH (minus any wrapped collateral): 100 snxETH
     *  If buy trade:
     *    - user is buying 10 ETH
     *    - skew fee = (100 / 1000 + 110 / 1000) / 2 = 0.105 = 10.5% = 1005 bips
     * sell trade would be the same, except -10.5% fee would be applied incentivizing user to sell which brings market closer to 0 skew.
     */
    function calculateSkewFee(
        FeeConfiguration.Data storage feeConfiguration,
        uint128 marketId,
        uint amount,
        uint synthPrice,
        Transaction.Type transactionType
    ) internal returns (int skewFee) {
        if (feeConfiguration.skewScale == 0) {
            return 0;
        }

        bool isBuyTrade = Transaction.isBuy(transactionType);
        bool isSellTrade = Transaction.isSell(transactionType);

        if (!isBuyTrade && !isSellTrade) {
            return 0;
        }

        uint skewScaleValue = feeConfiguration.skewScale.mulDecimal(synthPrice);

        uint totalSynthValue = (SynthUtil
            .getToken(marketId)
            .totalSupply()
            .mulDecimal(synthPrice)
            .toInt() + AsyncOrder.load(marketId).totalCommittedUsdAmount).toUint(); // add async order commitment amount in escrow

        Wrapper.Data storage wrapper = Wrapper.load(marketId);
        uint wrappedMarketCollateral = IMarketCollateralModule(SpotMarketFactory.load().synthetix)
            .getMarketCollateralAmount(marketId, wrapper.wrapCollateralType)
            .mulDecimal(synthPrice);

        int initialSkew = totalSynthValue.toInt() - wrappedMarketCollateral.toInt();
        int initialSkewAdjustment = initialSkew.divDecimal(skewScaleValue.toInt());

        int skewAfterFill = initialSkew;
        if (isBuyTrade) {
            skewAfterFill += amount.toInt();
        } else if (isSellTrade) {
            skewAfterFill -= amount.toInt();
        }

        int skewAfterFillAdjustment = skewAfterFill.divDecimal(skewScaleValue.toInt());
        int skewAdjustmentAveragePercentage = (skewAfterFillAdjustment + initialSkewAdjustment) / 2;

        skewFee = isSellTrade
            ? skewAdjustmentAveragePercentage * -1
            : skewAdjustmentAveragePercentage;
    }

    /**
     * @dev Calculates utilization rate fee
     *
     * If no utilizationFeeRate is set, then the fee is 0
     * The utilization rate fee is determined based on the ratio of outstanding synth value to the delegated collateral to the market.
     * Example:
     *  Utilization fee rate set to 0.1%
     *  Total delegated collateral value: $1000
     *  Total outstanding synth value = $1100
     *  User buys $100 worth of synths
     *  Before fill utilization rate: 1100 / 1000 = 110%
     *  After fill utilization rate: 1200 / 1000 = 120%
     *  Utilization Rate Delta = 120 - 110 = 10% / 2 (average) = 5%
     *  Fee charged = 5 * 0.001 (0.1%)  = 0.5%
     *
     */
    function calculateUtilizationRateFee(
        FeeConfiguration.Data storage feeConfiguration,
        uint128 marketId,
        uint amount,
        uint256 synthPrice
    ) internal view returns (uint utilFee) {
        if (feeConfiguration.utilizationFeeRate == 0) {
            return 0;
        }

        uint delegatedCollateral = IMarketManagerModule(SpotMarketFactory.load().synthetix)
            .getMarketCollateral(marketId);

        uint totalBalance = SynthUtil.getToken(marketId).totalSupply();

        // Note: take into account the async order commitment amount in escrow
        uint totalValueBeforeFill = (totalBalance.mulDecimal(synthPrice).toInt() +
            AsyncOrder.load(marketId).totalCommittedUsdAmount).toUint();
        uint totalValueAfterFill = totalValueBeforeFill + amount;

        // utilization is below 100%
        if (delegatedCollateral > totalValueAfterFill) {
            return 0;
        } else {
            uint preUtilization = totalValueBeforeFill.divDecimal(delegatedCollateral);
            // use 100% utilization if pre-fill utilization was less than 100%
            // no fees charged below 100% utilization
            uint preUtilizationDelta = preUtilization > 1e18 ? preUtilization - 1e18 : 0;
            uint postUtilization = totalValueAfterFill.divDecimal(delegatedCollateral);
            uint postUtilizationDelta = postUtilization - 1e18;

            // utilization is represented as the # of percentage points above 100%
            uint utilization = (preUtilizationDelta + postUtilizationDelta).mulDecimal(100e18) / 2;

            utilFee = utilization.mulDecimal(feeConfiguration.utilizationFeeRate);
        }
    }

    /**
     * @dev Runs the calculated fees through the Fee collector if it exists.
     *
     * The rest of the fees not collected by fee collector is deposited into the market manager
     * If no fee collector is specified, all fees are deposited into the market manager to help staker c-ratios.
     *
     */
    function collectFees(
        uint128 marketId,
        int totalFees,
        address transactor,
        Transaction.Type transactionType
    ) internal returns (uint collectedFees) {
        if (totalFees <= 0) {
            return 0;
        }

        uint totalFeesUint = totalFees.toUint();

        IFeeCollector feeCollector = FeeConfiguration.load(marketId).feeCollector;
        SpotMarketFactory.Data storage spotMarketFactory = SpotMarketFactory.load();

        if (address(feeCollector) != address(0)) {
            uint previousUsdBalance = spotMarketFactory.usdToken.balanceOf(address(this));

            spotMarketFactory.usdToken.approve(address(feeCollector), totalFeesUint);
            feeCollector.collectFees(marketId, totalFeesUint, transactor, uint8(transactionType));

            uint currentUsdBalance = spotMarketFactory.usdToken.balanceOf(address(this));
            collectedFees = previousUsdBalance - currentUsdBalance;

            spotMarketFactory.usdToken.approve(address(feeCollector), 0);
        }

        uint feesToDeposit = totalFeesUint - collectedFees;
        spotMarketFactory.depositToMarketManager(marketId, feesToDeposit);
    }

    function _applyFees(
        uint amount,
        int fees // 18 decimals
    ) private pure returns (uint amountUsable, int feesCollected) {
        feesCollected = fees.mulDecimal(amount.toInt());
        amountUsable = (amount.toInt() - feesCollected).toUint();
    }

    /*
     * @dev if special fee is set for a given transactor that takes precedence over the global fixed fees
     * otherwise, if async order, use async fixed fee, otherwise use atomic fixed fee
     */
    function _getFixedFee(
        FeeConfiguration.Data storage feeConfiguration,
        address transactor,
        bool async
    ) private view returns (uint fixedFee) {
        if (feeConfiguration.atomicFixedFeeOverrides[transactor] > 0) {
            fixedFee = feeConfiguration.atomicFixedFeeOverrides[transactor];
        } else {
            fixedFee = async ? feeConfiguration.asyncFixedFee : feeConfiguration.atomicFixedFee;
        }
    }
}
