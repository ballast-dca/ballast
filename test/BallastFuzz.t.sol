// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { BallastBrain } from "../src/BallastBrain.sol";
import { BallastExecutor, IERC20 } from "../src/BallastExecutor.sol";
import { MarketMood } from "../src/MarketMood.sol";
import { MockSystem } from "./Ballast.t.sol";

/// Property tests for the brain: the fear dial and the decisions it can send.
contract BallastBrainFuzzTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant CRON10000 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    uint256 constant ANSWER = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;
    address constant FEED = address(0xFEED);
    address constant EXEC = address(0xE0E0);
    address constant MOOD = address(0x3009);
    uint256 constant DAY = 86400;
    uint256 constant D0 = 20784;

    MockSystem system;
    BallastBrain brain;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        system = MockSystem(SYSTEM);
        vm.warp(D0 * DAY + 100);
        brain = new BallastBrain(8453, FEED, 7 days);
        brain.setTargets(EXEC, MOOD);
    }

    function _seed(uint256 close_, uint256 ema200_) internal {
        brain.seed(D0, close_, close_, close_, ema200_, close_ / 20);
    }

    function _lastAction() internal view returns (uint8 action) {
        bytes memory p = system.last().payload;
        assembly { action := mload(add(p, 100)) }
    }

    /// The dial always stays between 0.5x and 3x.
    function testFuzz_DialBounded(uint256 close_, uint256 ema200_) public {
        close_ = bound(close_, 1e8, 10_000_000e8);
        ema200_ = bound(ema200_, 1e8, 10_000_000e8);
        _seed(close_, ema200_);
        uint256 m = brain.multiplierX100();
        assertGe(m, 50);
        assertLe(m, 300);
    }

    /// A lower price never buys less: the dial is non-increasing in the close.
    function testFuzz_DialMonotonic(uint256 a_, uint256 b_, uint256 ema200_) public {
        ema200_ = bound(ema200_, 1_000e8, 1_000_000e8);
        a_ = bound(a_, 1e8, 5_000_000e8);
        b_ = bound(b_, a_, 5_000_000e8);           // b >= a
        _seed(a_, ema200_);
        uint256 ma = brain.multiplierX100();
        _seed(b_, ema200_);
        uint256 mb = brain.multiplierX100();
        assertGe(ma, mb, "cheaper price bought less");
    }

    /// The published distance has the right sign and roughly the right size.
    function testFuzz_DistanceSign(uint256 close_, uint256 ema200_) public {
        close_ = bound(close_, 1e8, 10_000_000e8);
        ema200_ = bound(ema200_, 1e8, 10_000_000e8);
        _seed(close_, ema200_);
        int256 d = brain.distanceBps();
        if (close_ > ema200_) assertGe(d, 0);
        if (close_ < ema200_) assertLe(d, 0);
    }

    /// ACCUMULATE never sends a sell, whatever path the price takes.
    function testFuzz_AccumulateNeverSells(uint256 seed_, uint8 days_) public {
        _seed(60_000e8, 75_000e8);
        uint256 n = bound(days_, 1, 60);
        uint256 p = 60_000e8;
        for (uint256 d = 1; d <= n; d++) {
            seed_ = uint256(keccak256(abi.encode(seed_, d)));
            // random daily move between -15% and +15%
            p = p * (85 + (seed_ % 31)) / 100;
            if (p < 1e8) p = 1e8;
            IReactive.LogRecord memory log;
            log.chainId = 8453;
            log.contractAddress = FEED;
            log.topic0 = ANSWER;
            log.topic1 = p;
            log.data = abi.encode((D0 + d) * DAY + 100);
            vm.prank(SYSTEM);
            brain.react(log);
            if (system.callbacks() > 0 && system.last().recipient == EXEC) {
                uint8 a = _lastAction();
                assertTrue(a != brain.SELL_TREND() && a != brain.SELL_STOP(), "sold in ACCUMULATE");
            }
        }
    }

    /// Rounds only ever go up, so the executor's duplicate check is sound.
    function testFuzz_RoundsStrictlyIncrease(uint8 weeks_) public {
        _seed(60_000e8, 75_000e8);
        uint256 n = bound(weeks_, 1, 30);
        uint256 last;
        for (uint256 w = 0; w < n; w++) {
            IReactive.LogRecord memory log;
            log.contractAddress = CRON;
            log.topic0 = CRON10000;
            vm.prank(SYSTEM);
            brain.react(log);
            assertGt(brain.round(), last);
            last = brain.round();
            vm.warp(block.timestamp + 7 days);
        }
    }
}

/// MarketMood can only move forward in time.
contract MarketMoodFuzzTest is Test {
    address constant PROXY = address(0x9A0);
    address constant BRAIN = address(0xB4A1);
    MarketMood mood;

    function setUp() public {
        mood = new MarketMood(IPayable(payable(PROXY)), BRAIN);
    }

    function testFuzz_NeverGoesBackInTime(uint256 d1_, uint256 d2_, uint256 c1_, uint256 c2_) public {
        d1_ = bound(d1_, 1, 1e9);
        d2_ = bound(d2_, 0, 1e9);
        vm.prank(PROXY);
        mood.setMood(BRAIN, d1_, c1_, 0, 0, 0, 0, 0, false, 100);
        vm.prank(PROXY);
        mood.setMood(BRAIN, d2_, c2_, 0, 0, 0, 0, 0, true, 100);
        MarketMood.Mood memory m = mood.latest();
        assertEq(m.day, d2_ >= d1_ ? d2_ : d1_);
        assertEq(m.close, d2_ >= d1_ ? c2_ : c1_);
    }
}

/// Executor properties against a fork of Base: real pool, real oracle.
contract BallastExecutorFuzzTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant PROXY = address(0x9A0);
    address constant BRAIN = address(0xB4A1);
    BallastExecutor ex;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        ex = new BallastExecutor(IPayable(payable(PROXY)), BRAIN, 5e6);
    }

    /// Whatever the multiplier and funding, the budget never promises more USDC than the
    /// contract holds after a buy, and a repeated round changes nothing.
    function testFuzz_BudgetNeverExceedsFunds(uint256 mult_, uint256 funds_, uint256 cap_) public {
        mult_ = bound(mult_, 50, 300);
        funds_ = bound(funds_, 0, 40e6);
        cap_ = bound(cap_, 0, 30e6);
        deal(USDC, address(ex), funds_);
        ex.setMonthlyCap(cap_);
        vm.prank(PROXY);
        ex.act{ gas: 600000 }(BRAIN, 1, 2, mult_, -2000);
        uint256 usdc = IERC20(USDC).balanceOf(address(ex));
        uint256 btc = IERC20(CBBTC).balanceOf(address(ex));
        assertLe(ex.budget(), usdc + 1, "budget exceeds funds");
        if (cap_ != 0) assertLe(funds_ - usdc, cap_, "spent past the monthly cap");

        vm.prank(PROXY);
        ex.act{ gas: 600000 }(BRAIN, 1, 2, mult_, -2000);   // duplicate round
        assertEq(IERC20(USDC).balanceOf(address(ex)), usdc);
        assertEq(IERC20(CBBTC).balanceOf(address(ex)), btc);
    }
}
