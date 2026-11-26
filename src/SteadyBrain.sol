// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// Steady: DCA that buys more when the market is afraid.
//
// SteadyBrain is the reactive contract (Reactive Network). It listens to three
// event streams and decides; SteadyExecutor and MarketMood on Base only act.
//
//   1. Chainlink BTC/USD AnswerUpdated on Base -> daily high/low/close, then
//      EMA20/50/200 and ATR14 computed on-chain, and a daily Market Mood
//      published to Base (distance from the 200-day average, trend state).
//   2. Reactive Cron10000 -> once per `interval`, the weekly buy. In
//      ACCUMULATE mode the amount follows the fear dial: 1x normally, up to 3x
//      the further price sits below its 200-day average, down to 0.5x when
//      price is far above it. In SHIELD mode the week's budget is released but
//      only invested while the trend is up.
//   3. SteadyExecutor's Bought / Sold events on Base -> the brain's view of the
//      position follows what actually happened on-chain.
//
// SHIELD mode also exits to USDC when the trend breaks (close < EMA200 or
// EMA20 < EMA50) or price hits a disaster stop (last buy - 3 x ATR).

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

contract SteadyBrain is AbstractReactive {
    error NotOwner(address caller_);

    event Decision(uint256 indexed round_, uint8 action_, uint256 multX100_, int256 distanceBps_, uint256 price_);
    event DailyClose(uint256 indexed day_, uint256 close_, uint256 ema20_, uint256 ema50_, uint256 ema200_,
        uint256 atr_, bool up_);
    event ModeChanged(uint8 mode_);

    // Modes.
    uint8 public constant ACCUMULATE = 1;     // fear dial, always buying
    uint8 public constant SHIELD = 2;         // trend-gated, exits on trend break or stop

    // Actions understood by SteadyExecutor.act().
    uint8 public constant WEEK_ONLY = 1;      // release the weekly budget, stay in cash
    uint8 public constant WEEK_AND_BUY = 2;   // release the weekly budget (x multiplier) and buy with all idle budget
    uint8 public constant BUY = 3;            // buy with all idle budget (trend just turned UP, SHIELD)
    uint8 public constant SELL_TREND = 4;     // exit to USDC: trend is DOWN (SHIELD)
    uint8 public constant SELL_STOP = 5;      // exit to USDC: disaster stop hit (SHIELD)

    uint64 private constant ACT_GAS_LIMIT = 600000;
    uint64 private constant MOOD_GAS_LIMIT = 200000;
    uint256 private constant ANSWER_UPDATED = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;
    uint256 private constant CRON10000 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    address private constant CRON_EMITTER = 0x0000000000000000000000000000000000fffFfF;
    uint256 private constant DAY = 86400;
    uint256 private constant STOP_ATR = 3;

    address private immutable _owner;
    uint256 private immutable _chainId;      // Base
    address private immutable _feed;         // Chainlink BTC/USD aggregator on Base
    uint256 private immutable _boughtTopic;
    uint256 private immutable _soldTopic;
    address public executor;
    address public mood;

    uint8 public mode = ACCUMULATE;
    uint256 public interval;                 // seconds between weekly buys
    uint256 public lastWeek;
    uint256 public round;

    bool public seeded;
    uint256 public day;
    uint256 public dayHigh;
    uint256 public dayLow;
    uint256 public lastPrice;
    uint256 public prevClose;
    uint256 public ema20;
    uint256 public ema50;
    uint256 public ema200;
    uint256 public atr;
    bool public up;

    bool public holding;
    bool public blocked;                     // SHIELD: after a stop, no re-entry until the trend resets
    bool public exitPending;
    uint8 public pendingExit;                // SELL_TREND or SELL_STOP, kept for retries
    uint256 public stopPrice;

    // `payable` so the contract can be funded at deployment.
    constructor(uint256 chainId_, address feed_, uint256 interval_) payable {
        _owner = msg.sender;
        _chainId = chainId_;
        _feed = feed_;
        interval = interval_;
        _boughtTopic = uint256(keccak256("Bought(uint256,uint256,uint256,uint256)"));
        _soldTopic = uint256(keccak256("Sold(uint256,uint256,uint256,uint256)"));
        _subscribeCore();
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Set once SteadyExecutor and MarketMood are deployed; subscribes to the executor's events.
    function setTargets(address executor_, address mood_) external onlyOwner {
        executor = executor_;
        mood = mood_;
        SYSTEM.subscribe(_chainId, executor_, _boughtTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(_chainId, executor_, _soldTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Seed indicator state from completed daily candles (off-chain), all in 8-decimal feed units.
    function seed(uint256 day_, uint256 prevClose_, uint256 ema20_, uint256 ema50_, uint256 ema200_, uint256 atr_)
        external
        onlyOwner
    {
        day = day_;
        prevClose = prevClose_;
        lastPrice = prevClose_;
        dayHigh = prevClose_;
        dayLow = prevClose_;
        ema20 = ema20_;
        ema50 = ema50_;
        ema200 = ema200_;
        atr = atr_;
        up = _trendUp(prevClose_);
        seeded = true;
    }

    function setMode(uint8 mode_) external onlyOwner {
        require(mode_ == ACCUMULATE || mode_ == SHIELD, "mode");
        mode = mode_;
        blocked = false;
        emit ModeChanged(mode_);
    }

    function setInterval(uint256 interval_) external onlyOwner {
        interval = interval_;
    }

    /// @notice Stop paying for price and cron reactions. Executor events only arrive after actions.
    function pause() external onlyOwner {
        _unsubscribeCore();
    }

    /// @notice Resume. Settles debt from the balance first: a contract in debt receives nothing.
    function resume() external payable onlyOwner {
        _coverDebt();
        _subscribeCore();
    }

    /// @notice Fear dial, x100: 100 at or near the 200-day average, +5 per 1% below it (cap 300),
    /// and -1 per 1% above 130% of it (floor 50).
    function multiplierX100() public view returns (uint256) {
        uint256 c = prevClose;
        if (ema200 == 0) return 100;
        if (c < ema200) {
            uint256 extra = ((ema200 - c) * 500) / ema200;
            return 100 + (extra > 200 ? 200 : extra);
        }
        uint256 pct = (c * 100) / ema200;
        if (pct <= 130) return 100;
        uint256 skim = pct - 130;
        return skim >= 50 ? 50 : 100 - skim;
    }

    /// @notice Signed distance of the last daily close from the 200-day average, in basis points.
    function distanceBps() public view returns (int256) {
        if (ema200 == 0) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        return ((int256(prevClose) - int256(ema200)) * 10000) / int256(ema200);
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        // Return early instead of reverting: a reverted reaction is still charged.
        if (!seeded || executor == address(0)) return;
        if (log_.contractAddress == CRON_EMITTER && log_.topic0 == CRON10000) {
            _onCron();
        } else if (log_.chainId == _chainId && log_.contractAddress == _feed) {
            _onPrice(log_);
        } else if (log_.chainId == _chainId && log_.contractAddress == executor) {
            _onExecutor(log_);
        }
    }

    function _onCron() internal {
        if (block.timestamp < lastWeek + interval) return;
        lastWeek = block.timestamp;
        if (mode == ACCUMULATE) {
            _act(WEEK_AND_BUY, multiplierX100());
        } else {
            _act((up && !blocked) ? WEEK_AND_BUY : WEEK_ONLY, 100);
        }
    }

    function _onPrice(LogRecord calldata log_) internal {
        // topic1 holds the int256 answer bit for bit; negatives are rejected below.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 answer = int256(log_.topic1);
        if (answer <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer);
        uint256 bucket = abi.decode(log_.data, (uint256)) / DAY;

        if (bucket > day) {
            _closeDay(lastPrice);
            day = bucket;
            dayHigh = price;
            dayLow = price;
        } else {
            if (price > dayHigh) dayHigh = price;
            if (price < dayLow) dayLow = price;
        }
        lastPrice = price;

        if (mode == SHIELD && holding && !exitPending && stopPrice != 0 && price <= stopPrice) {
            blocked = true;
            _exit(SELL_STOP);
        }
    }

    function _closeDay(uint256 close_) internal {
        ema20 = _ema(ema20, close_, 20);
        ema50 = _ema(ema50, close_, 50);
        ema200 = _ema(ema200, close_, 200);
        uint256 tr = dayHigh - dayLow;
        uint256 upMove = dayHigh > prevClose ? dayHigh - prevClose : prevClose - dayHigh;
        uint256 downMove = dayLow > prevClose ? dayLow - prevClose : prevClose - dayLow;
        if (upMove > tr) tr = upMove;
        if (downMove > tr) tr = downMove;
        atr = (atr * 13 + tr) / 14;
        prevClose = close_;

        bool wasUp = up;
        up = _trendUp(close_);
        emit DailyClose(day, close_, ema20, ema50, ema200, atr, up);
        _publishMood();

        if (mode != SHIELD) return;
        if (!up) blocked = false;            // a DOWN trend clears a stop block
        if (holding && exitPending) {
            // Retry an exit the executor skipped (stale oracle, failed swap): no Sold event came back.
            // A duplicate is harmless; the executor finds nothing left to sell and skips.
            _act(pendingExit, 100);
        } else if (holding && !up) {
            _exit(SELL_TREND);
        } else if (up && !wasUp && !blocked) {
            _act(BUY, 100);
        }
    }

    function _onExecutor(LogRecord calldata log_) internal {
        if (log_.topic0 == _boughtTopic) {
            (,, uint256 price) = abi.decode(log_.data, (uint256, uint256, uint256));
            holding = true;
            stopPrice = price > STOP_ATR * atr ? price - STOP_ATR * atr : 0;
        } else if (log_.topic0 == _soldTopic) {
            holding = false;
            exitPending = false;
            stopPrice = 0;
        }
    }

    function _exit(uint8 action_) internal {
        exitPending = true;
        pendingExit = action_;
        _act(action_, 100);
    }

    function _act(uint8 action_, uint256 multX100_) internal {
        round++;
        int256 dist = distanceBps();
        emit Decision(round, action_, multX100_, dist, lastPrice);
        _callback(executor, ACT_GAS_LIMIT, abi.encodeWithSignature(
            "act(address,uint256,uint8,uint256,int256)",
            address(0) /* replaced with this contract's address */,
            round,
            action_,
            multX100_,
            dist
        ));
    }

    function _publishMood() internal {
        if (mood == address(0)) return;
        _callback(mood, MOOD_GAS_LIMIT, abi.encodeWithSignature(
            "setMood(address,uint256,uint256,uint256,uint256,uint256,uint256,int256,bool,uint256)",
            address(0) /* replaced with this contract's address */,
            day,
            prevClose,
            ema20,
            ema50,
            ema200,
            atr,
            distanceBps(),
            up,
            multiplierX100()
        ));
    }

    function _callback(address recipient_, uint64 gasLimit_, bytes memory payload_) internal {
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
            chainId: _chainId,
            recipient: recipient_,
            gasLimit: gasLimit_,
            payload: payload_
        }));
    }

    function _trendUp(uint256 close_) internal view returns (bool) {
        return close_ > ema200 && ema20 > ema50;
    }

    function _ema(uint256 prev_, uint256 close_, uint256 n_) internal pure returns (uint256) {
        if (close_ >= prev_) return prev_ + ((close_ - prev_) * 2) / (n_ + 1);
        return prev_ - ((prev_ - close_) * 2) / (n_ + 1);
    }

    // subscribe() and unsubscribe() share the same six arguments: an unsubscribe that differs does nothing.
    function _subscribeCore() internal {
        SYSTEM.subscribe(_chainId, _feed, ANSWER_UPDATED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(block.chainid, CRON_EMITTER, CRON10000, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _unsubscribeCore() internal {
        SYSTEM.unsubscribe(_chainId, _feed, ANSWER_UPDATED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(block.chainid, CRON_EMITTER, CRON10000, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }
}
