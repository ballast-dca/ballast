// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { SteadyBrain } from "../src/SteadyBrain.sol";
import { SteadyExecutor, IERC20 } from "../src/SteadyExecutor.sol";

/// Stands in for the Reactive system contract in unit tests.
contract MockSystem {
    uint256 public subscriptions;
    uint256 public callbacks;
    ISystemContract.CallbackConfiguration_V_1_0 internal _last;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions--;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbacks++;
        _last = config_;
    }

    function last() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return _last;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}

contract SteadyBrainTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant CRON10000 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    uint256 constant ANSWER = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;
    address constant FEED = address(0xFEED);
    address constant EXEC = address(0xE0E0);
    uint256 constant DAY = 86400;
    uint256 constant D0 = 20784;

    MockSystem system;
    SteadyBrain brain;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        system = MockSystem(SYSTEM);
        vm.warp(D0 * DAY + 100);
        brain = new SteadyBrain(8453, FEED, 7 days);
        brain.setExecutor(EXEC);
        // Downtrend seed, like late Nov 2026: close 60k under EMA200 75k, EMA20 < EMA50, ATR 2k.
        brain.seed(D0, 60_000e8, 61_000e8, 66_000e8, 75_000e8, 2_000e8);
    }

    function _log(address from_, uint256 topic0_, uint256 topic1_, bytes memory data_, uint256 chainId_)
        internal
    {
        IReactive.LogRecord memory log;
        log.chainId = chainId_;
        log.contractAddress = from_;
        log.topic0 = topic0_;
        log.topic1 = topic1_;
        log.data = data_;
        vm.prank(SYSTEM);
        brain.react(log);
    }

    function _price(uint256 p_, uint256 at_) internal {
        _log(FEED, ANSWER, p_, abi.encode(at_), 8453);
    }

    function _cron() internal {
        _log(CRON, CRON10000, 0, abi.encode(block.number), block.chainid);
    }

    function _bought(uint256 price_) internal {
        _log(EXEC, uint256(keccak256("Bought(uint256,uint256,uint256,uint256)")), 1,
            abi.encode(uint256(10e6), uint256(1), price_), 8453);
    }

    function _sold() internal {
        _log(EXEC, uint256(keccak256("Sold(uint256,uint256,uint256,uint256)")), 1,
            abi.encode(uint256(1), uint256(10e6), uint256(1)), 8453);
    }

    function _lastAction() internal view returns (uint8 action) {
        bytes memory p = system.last().payload;
        assembly { action := mload(add(p, 100)) }
    }

    function test_SubscribesToFeedCronAndExecutor() public view {
        assertEq(system.subscriptions(), 4);
    }

    function test_WeeklyInDowntrendOnlyReleasesBudget() public {
        _cron();
        assertEq(system.callbacks(), 1);
        assertEq(_lastAction(), brain.WEEK_ONLY());
        _cron();
        assertEq(system.callbacks(), 1, "fired twice in one interval");
        vm.warp(block.timestamp + 7 days);
        _cron();
        assertEq(system.callbacks(), 2);
    }

    function test_RallyFlipsUpAndBuysThenWeeklyBuys() public {
        uint256 p = 80_000e8;
        for (uint256 d = 0; d < 40 && !brain.up(); d++) {
            _price(p, (D0 + d) * DAY + 100);
            p += 1_000e8;
        }
        assertTrue(brain.up(), "regime never turned UP");
        assertEq(_lastAction(), brain.BUY());
        _cron();
        assertEq(_lastAction(), brain.WEEK_AND_BUY());
    }

    function test_StopFiresOnceAndBlocksReentry() public {
        _bought(60_000e8);                         // stop = 60k - 3 x 2k = 54k
        assertEq(brain.stopPrice(), 54_000e8);
        _price(55_000e8, D0 * DAY + 200);
        uint256 before = system.callbacks();
        _price(53_900e8, D0 * DAY + 300);
        assertEq(system.callbacks(), before + 1);
        assertEq(_lastAction(), brain.SELL_STOP());
        _price(53_000e8, D0 * DAY + 400);
        assertEq(system.callbacks(), before + 1, "stop fired twice");
        assertTrue(brain.blocked());
        _sold();
        assertFalse(brain.holding());
    }

    function test_TrendBreakSellsHolding() public {
        uint256 p = 80_000e8;
        for (uint256 d = 0; d < 40 && !brain.up(); d++) {
            _price(p, (D0 + d) * DAY + 100);
            p += 1_000e8;
        }
        _bought(p);
        uint256 day = brain.day();
        for (uint256 d = 1; d < 60 && brain.up(); d++) {
            _price(p, (day + d) * DAY + 100);
            p = p > 3_000e8 ? p - 3_000e8 : p;
        }
        assertFalse(brain.up(), "regime never turned DOWN");
        assertTrue(brain.exitPending() || _lastAction() == brain.SELL_STOP());
    }

    function test_SkippedExitIsRetriedDaily() public {
        _bought(60_000e8);
        _price(53_000e8, D0 * DAY + 300);          // stop fires
        assertEq(_lastAction(), brain.SELL_STOP());
        uint256 before = system.callbacks();
        // No Sold event comes back (executor skipped). Next daily close retries the exit.
        _price(53_500e8, (D0 + 1) * DAY + 100);
        assertEq(system.callbacks(), before + 1);
        assertEq(_lastAction(), brain.SELL_STOP());
        _sold();
        _price(53_500e8, (D0 + 2) * DAY + 100);
        assertEq(system.callbacks(), before + 1, "retried after Sold arrived");
    }

    function test_IgnoresStrangers() public {
        _log(address(0xBAD), ANSWER, 1e8, abi.encode(D0 * DAY + 5 * DAY), 8453);
        assertEq(brain.lastPrice(), 60_000e8);
        assertEq(system.callbacks(), 0);
    }

    function test_OnlySystemCanReact() public {
        IReactive.LogRecord memory log;
        vm.expectRevert();
        brain.react(log);
    }
}

/// Runs against a fork of Base mainnet: real Uniswap v3 cbBTC/USDC pool and real Chainlink feed.
contract SteadyExecutorForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant PROXY = address(0x9A0);
    address constant BRAIN = address(0xB4A1);

    SteadyExecutor ex;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        ex = new SteadyExecutor(IPayable(payable(PROXY)), BRAIN, 10e6);
        deal(USDC, address(ex), 50e6);
    }

    function _act(uint256 round_, uint8 action_) internal {
        vm.prank(PROXY);
        ex.act{ gas: 600000 }(BRAIN, round_, action_);
    }

    function test_WeekOnlyAccumulatesBudget() public {
        _act(1, 1);
        _act(2, 1);
        assertEq(ex.budget(), 20e6);
        assertEq(IERC20(CBBTC).balanceOf(address(ex)), 0);
    }

    function test_BuyDeploysWholeBudgetThenSellReturnsToBudget() public {
        _act(1, 1);
        _act(2, 1);
        _act(3, 3);                                // regime UP: buy all 20 USDC
        uint256 btc = IERC20(CBBTC).balanceOf(address(ex));
        assertGt(btc, 0);
        assertEq(ex.budget(), 0);
        emit log_named_decimal_uint("cbBTC bought for 20 USDC", btc, 8);

        _act(4, 4);                                // trend break: sell all
        assertEq(IERC20(CBBTC).balanceOf(address(ex)), 0);
        assertGt(ex.budget(), 19.9e6);             // round trip costs ~0.1% plus price impact
        emit log_named_decimal_uint("USDC back after round trip", ex.budget(), 6);
    }

    function test_DuplicateAndPausedSkip() public {
        _act(1, 2);
        uint256 btc = IERC20(CBBTC).balanceOf(address(ex));
        _act(1, 2);
        assertEq(IERC20(CBBTC).balanceOf(address(ex)), btc);
        ex.setPaused(true);
        _act(2, 2);
        assertEq(IERC20(CBBTC).balanceOf(address(ex)), btc);
    }

    function test_TightSlippageSkipsInsteadOfReverting() public {
        ex.setSlippageBps(0);
        _act(1, 1);
        // Pool fee alone (0.05%) breaks a zero-slippage guard: the buy must skip, not revert.
        _act(2, 3);
        assertEq(IERC20(CBBTC).balanceOf(address(ex)), 0);
        assertEq(ex.budget(), 10e6);
    }

    function test_OnlyProxyBrainAndPool() public {
        vm.expectRevert();
        ex.act(BRAIN, 1, 1);
        vm.prank(PROXY);
        vm.expectRevert();
        ex.act(address(0xBAD), 1, 1);
        vm.expectRevert();
        ex.uniswapV3SwapCallback(1, 0, "");
        vm.expectRevert();
        ex.swap(true, 1, 0);
    }
}
