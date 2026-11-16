// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RewardMathHarness} from "../src/RewardMathHarness.sol";

/// @notice Fuzz the deployed emission schedule math (live pool 0 params) for
/// additivity: splitting a period must never create or destroy MOR, or an
/// attacker could over-mint by calling distributeRewards at chosen times.
contract RewardMathTest is Test {
    RewardMathHarness h;

    uint256 constant INITIAL = 3456 ether;
    uint256 constant DECREASE = 592558728240000000;
    uint128 constant PAYOUT_START = 1707393600;
    uint128 constant INTERVAL = 86400;

    function setUp() public {
        h = new RewardMathHarness();
    }

    function testAdditivity(uint128 a, uint128 b, uint128 c) public view {
        // Stay inside the emission window so the schedule is live.
        a = uint128(bound(a, PAYOUT_START, PAYOUT_START + 5000 days));
        b = uint128(bound(b, a, a + 30 days));
        c = uint128(bound(c, b, b + 30 days));
        uint256 whole = h.getPeriodReward(INITIAL, DECREASE, PAYOUT_START, INTERVAL, a, c);
        uint256 first = h.getPeriodReward(INITIAL, DECREASE, PAYOUT_START, INTERVAL, a, b);
        uint256 second = h.getPeriodReward(INITIAL, DECREASE, PAYOUT_START, INTERVAL, b, c);
        // Splitting must never create MOR: split sum <= whole, and any
        // shortfall is integer-division dust (observed max 1 wei).
        assertLe(first + second, whole, "period split over-mints MOR");
        assertLe(whole - (first + second), 2, "period split shortfall exceeds dust");
    }

    function testTotalEmissionMatchesSchedule() public view {
        // Sum of daily slices must equal the whole-window reward.
        uint256 total = h.getPeriodReward(INITIAL, DECREASE, PAYOUT_START, INTERVAL, PAYOUT_START, PAYOUT_START + 6000 days);
        uint256 sum;
        for (uint256 d = 0; d < 6000; d++) {
            uint128 s = uint128(PAYOUT_START + d * 1 days);
            sum += h.getPeriodReward(INITIAL, DECREASE, PAYOUT_START, INTERVAL, s, s + 1 days);
        }
        assertEq(sum, total, "daily slices do not sum to whole window");
    }
}
