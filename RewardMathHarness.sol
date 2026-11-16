// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LinearDistributionIntervalDecrease} from "./LinearDistributionIntervalDecrease.sol";

/// @notice Thin harness over the exact library source deployed with RewardPool,
/// so the emission math can be fuzzed without the full protocol deployment.
contract RewardMathHarness {
    function getPeriodReward(
        uint256 initialAmount_,
        uint256 decreaseAmount_,
        uint128 payoutStart_,
        uint128 interval_,
        uint128 startTime_,
        uint128 endTime_
    ) external pure returns (uint256) {
        return
            LinearDistributionIntervalDecrease.getPeriodReward(
                initialAmount_,
                decreaseAmount_,
                payoutStart_,
                interval_,
                startTime_,
                endTime_
            );
    }
}
