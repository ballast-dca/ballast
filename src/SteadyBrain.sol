// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// Steady: DCA that steps aside when the trend breaks.
//
// SteadyBrain is the reactive contract (Reactive Network). It listens to three
// event streams and decides; SteadyExecutor on Base only executes.
//
//   1. Chainlink BTC/USD AnswerUpdated on Base -> daily high/low/close, then
//      EMA20/50/200 and ATR14 computed on-chain. Regime is UP when
//      close > EMA200 and EMA20 > EMA50. Intraday, a disaster stop at
//      (last buy price - 3 x ATR) is checked on every price update.
//   2. Reactive Cron10000 -> once per `interval`, release the weekly budget
//      (and buy if the regime is UP).
//   3. SteadyExecutor's Bought / Sold events on Base -> the brain's view of the
//      position always follows what actually happened on-chain.

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

contract SteadyBrain is AbstractReactive {
    error NotOwner(address caller_);

    event Decision(uint256 indexed round_, uint8 action_, uint256 price_);
    event DailyClose(uint256 indexed day_, uint256 close_, uint256 ema20_, uint256 ema50_, uint256 ema200_,
        uint256 atr_, bool up_);

    // Actions understood by SteadyExecutor.act().
    uint8 public constant WEEK_ONLY = 1;      // release the weekly budget, stay in cash
    uint8 public constant WEEK_AND_BUY = 2;   // release the weekly budget and buy with all idle budget
    uint8 public constant BUY = 3;            // buy with all idle budget (regime just turned UP)
    uint8 public constant SELL_TREND = 4;     // exit to USDC: regime turned DOWN
    uint8 public constant SELL_STOP = 5;      // exit to USDC: disaster stop hit

    uint64 private constant CALLBACK_GAS_LIMIT = 600000;
    uint256 private constant ANSWER_UPDATED = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;
    uint256 private constant CRON10000 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    uint256 private constant BOUGHT = 0x47abb63d521dd2e26fcdd6dd304df0a109af421045f9cf9d53a6d1b7f5c16376;
    address private constant CRON_EMITTER = 0x0000000000000000000000000000000000fffFfF;
    uint256 private constant DAY = 86400;
    uint256 private constant STOP_ATR = 3;

    address private immutable _owner;
    uint256 private immutable _chainId;      // Base
    address private immutable _feed;         // Chainlink BTC/USD aggregator on Base
    uint256 private immutable _soldTopic;
    address public executor;

    uint256 public interval;                 // seconds between weekly budget releases
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
    bool public blocked;                     // after a stop: no re-entry until the regime resets
    bool public exitPending;
    uint256 public stopPrice;

    // `payable` so the contract can be funded at deployment.
    constructor(uint256 chainId_, address feed_, uint256 interval_) payable {
        _owner = msg.sender;
        _chainId = chainId_;
        _feed = feed_;
        interval = interval_;
        _soldTopic = uint256(keccak256("Sold(uint256,uint256,uint256,uint256)"));
        _subscribeCore();
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Set once SteadyExecutor is deployed; subscribes to its Bought and Sold events.
    function setExecutor(address executor_) external onlyOwner {
        executor = executor_;
        SYSTEM.subscribe(_chainId, executor_, BOUGHT, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
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
        up = _regimeUp(prevClose_);
        seeded = true;
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

    // subscribe() and unsubscribe() share the same six arguments: an unsubscribe that differs does nothing.
    function _subscribeCore() internal {
        SYSTEM.subscribe(_chainId, _feed, ANSWER_UPDATED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(block.chainid, CRON_EMITTER, CRON10000, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _unsubscribeCore() internal {
        SYSTEM.unsubscribe(_chainId, _feed, ANSWER_UPDATED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(block.chainid, CRON_EMITTER, CRON10000, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
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
        _act((up && !blocked) ? WEEK_AND_BUY : WEEK_ONLY);
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

        if (holding && !exitPending && stopPrice != 0 && price <= stopPrice) {
            blocked = true;
            exitPending = true;
            _act(SELL_STOP);
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

        bool nowUp = _regimeUp(close_);
        emit DailyClose(day, close_, ema20, ema50, ema200, atr, nowUp);
        // Retry an exit the executor skipped (stale oracle, failed swap): no Sold event came back.
        // A duplicate is harmless; the executor finds nothing left to sell and skips.
        if (holding && exitPending) _act(blocked ? SELL_STOP : SELL_TREND);
        if (nowUp == up) return;
        up = nowUp;
        if (!nowUp) {
            blocked = false;                 // the regime reset clears a stop block
            if (holding && !exitPending) {
                exitPending = true;
                _act(SELL_TREND);
            }
        } else if (!blocked) {
            _act(BUY);
        }
    }

    function _onExecutor(LogRecord calldata log_) internal {
        if (log_.topic0 == BOUGHT) {
            (,, uint256 price) = abi.decode(log_.data, (uint256, uint256, uint256));
            holding = true;
            stopPrice = price > STOP_ATR * atr ? price - STOP_ATR * atr : 0;
        } else if (log_.topic0 == _soldTopic) {
            holding = false;
            exitPending = false;
            stopPrice = 0;
        }
    }

    function _act(uint8 action_) internal {
        round++;
        emit Decision(round, action_, lastPrice);
        bytes memory payload = abi.encodeWithSignature(
            "act(address,uint256,uint8)",
            address(0) /* replaced with this contract's address */,
            round,
            action_
        );
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
            chainId: _chainId,
            recipient: executor,
            gasLimit: CALLBACK_GAS_LIMIT,
            payload: payload
        }));
    }

    function _regimeUp(uint256 close_) internal view returns (bool) {
        return close_ > ema200 && ema20 > ema50;
    }

    function _ema(uint256 prev_, uint256 close_, uint256 n_) internal pure returns (uint256) {
        if (close_ >= prev_) return prev_ + ((close_ - prev_) * 2) / (n_ + 1);
        return prev_ - ((prev_ - close_) * 2) / (n_ + 1);
    }
}
