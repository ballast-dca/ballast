// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// Steady: DCA that buys more when the market is afraid.
//
// SteadyExecutor is the callback contract on Base. It holds the user's USDC
// and cbBTC and only does what SteadyBrain (on Reactive) tells it to:
// release the weekly budget (times the fear-dial multiplier), buy cbBTC with
// the idle budget, or sell everything back to USDC (SHIELD mode). A monthly
// cap bounds how much the dial can spend in a long crash. Every swap is guarded against the Chainlink
// BTC/USD price on Base, read directly here, so no manual price ceiling.
// A failed or stale-oracle swap is skipped, never reverted, so callbacks
// always settle and nothing strands.

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20 {
    function balanceOf(address account_) external view returns (uint256);
    function transfer(address to_, uint256 amount_) external returns (bool);
}

interface IUniswapV3Pool {
    function swap(address recipient_, bool zeroForOne_, int256 amountSpecified_, uint160 sqrtPriceLimitX96_,
        bytes calldata data_) external returns (int256 amount0_, int256 amount1_);
}

interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract SteadyExecutor is AbstractCallback {
    error NotOwner(address caller_);
    error NotPool(address caller_);
    error NotSelf(address caller_);
    error TooLittleOut(uint256 out_, uint256 minOut_);

    event Bought(uint256 indexed round_, uint256 usdcIn_, uint256 btcOut_, uint256 price_);
    event Sold(uint256 indexed round_, uint256 btcIn_, uint256 usdcOut_, uint256 price_);
    event BudgetReleased(uint256 indexed round_, uint256 amount_, uint256 budget_);
    event Skipped(uint256 indexed round_, uint8 action_, uint8 reason_);
    event Explained(uint256 indexed round_, uint8 action_, uint256 multX100_, int256 distanceBps_);

    IUniswapV3Pool public constant POOL = IUniswapV3Pool(0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef);
    IAggregatorV3 public constant ORACLE = IAggregatorV3(0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F);
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;   // pool token0
    address public constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;  // pool token1
    uint160 private constant MIN_SQRT_PLUS_ONE = 4295128740;
    uint160 private constant MAX_SQRT_MINUS_ONE = 1461446703485210103287273052203988822378723970341;
    uint256 public constant MAX_ORACLE_AGE = 2 hours;

    uint8 public constant WEEK_ONLY = 1;
    uint8 public constant WEEK_AND_BUY = 2;
    uint8 public constant BUY = 3;
    uint8 public constant SELL_TREND = 4;
    uint8 public constant SELL_STOP = 5;

    uint8 public constant DUPLICATE = 1;
    uint8 public constant PAUSED = 2;
    uint8 public constant NOTHING = 3;
    uint8 public constant STALE_ORACLE = 4;
    uint8 public constant SWAP_FAILED = 5;
    uint8 public constant CAPPED = 6;

    address public immutable owner;
    uint256 public weekly;          // USDC (6 decimals) released per week
    uint256 public budget;          // released USDC waiting to be invested
    uint256 public slippageBps = 100;
    bool public paused;
    uint256 public lastRound;
    uint256 public monthlyCap;      // USDC (6 decimals) the buys may spend per 30 days; 0 = no cap
    uint256 public windowStart;
    uint256 public spentInWindow;

    // `payable` so the contract can be funded at deployment.
    // callbackProxy_: the callback proxy on this chain. callbackSender_: SteadyBrain (immutable).
    constructor(IPayable callbackProxy_, address callbackSender_, uint256 weekly_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        owner = msg.sender;
        weekly = weekly_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Entry point for SteadyBrain's callbacks. The network replaces `rc` with the brain's address.
    function act(address rc, uint256 round, uint8 action, uint256 multX100, int256 distanceBps)
        external
        onlyServiceProvider
        onlyCallbackSender(rc)
    {
        // Idempotent: the same origin event can arrive twice.
        if (round <= lastRound) { _skip(round, action, DUPLICATE); return; }
        lastRound = round;
        if (paused) { _skip(round, action, PAUSED); return; }
        emit Explained(round, action, multX100, distanceBps);

        if (action == WEEK_ONLY || action == WEEK_AND_BUY) {
            uint256 release = weekly * multX100 / 100;
            budget += release;
            emit BudgetReleased(round, release, budget);
        }
        if (action == WEEK_AND_BUY || action == BUY) {
            _buy(round, action);
        } else if (action == SELL_TREND || action == SELL_STOP) {
            _sellAll(round, action);
        }
    }

    function _buy(uint256 round_, uint8 action_) internal {
        uint256 usdc = IERC20(USDC).balanceOf(address(this));
        uint256 spend = budget < usdc ? budget : usdc;
        if (monthlyCap != 0) {
            if (block.timestamp >= windowStart + 30 days) {
                windowStart = block.timestamp;
                spentInWindow = 0;
            }
            uint256 room = monthlyCap > spentInWindow ? monthlyCap - spentInWindow : 0;
            if (spend > room) spend = room;
            if (spend == 0) { _skip(round_, action_, CAPPED); return; }
        }
        if (spend == 0) { _skip(round_, action_, NOTHING); return; }
        (bool fresh, uint256 p) = _oracle();
        if (!fresh) { _skip(round_, action_, STALE_ORACLE); return; }
        // cbBTC 8 decimals, USDC 6, oracle 8: btc = usdc * 1e10 / price.
        uint256 minOut = (spend * 1e10 / p) * (10000 - slippageBps) / 10000;
        try this.swap(true, spend, minOut) returns (uint256 out) {
            budget -= spend;
            spentInWindow += spend;
            uint256 left = IERC20(USDC).balanceOf(address(this));
            if (budget > left) budget = left;        // the dial cannot promise money that is not there
            emit Bought(round_, spend, out, spend * 1e10 / out);
        } catch {
            _skip(round_, action_, SWAP_FAILED);
        }
    }

    function _sellAll(uint256 round_, uint8 action_) internal {
        uint256 btc = IERC20(CBBTC).balanceOf(address(this));
        if (btc == 0) { _skip(round_, action_, NOTHING); return; }
        (bool fresh, uint256 p) = _oracle();
        if (!fresh) { _skip(round_, action_, STALE_ORACLE); return; }
        uint256 minOut = (btc * p / 1e10) * (10000 - slippageBps) / 10000;
        try this.swap(false, btc, minOut) returns (uint256 out) {
            budget += out;                   // proceeds wait in cash for the next UP regime
            emit Sold(round_, btc, out, out * 1e10 / btc);
        } catch {
            _skip(round_, action_, SWAP_FAILED);
        }
    }

    /// @notice Self-call wrapper so a failed swap reverts as a unit and act() can catch it.
    function swap(bool usdcToBtc_, uint256 amountIn_, uint256 minOut_) external returns (uint256 out) {
        if (msg.sender != address(this)) revert NotSelf(msg.sender);
        (int256 a0, int256 a1) = POOL.swap(
            address(this),
            usdcToBtc_,
            // forge-lint: disable-next-line(unsafe-typecast)
            int256(amountIn_),
            usdcToBtc_ ? MIN_SQRT_PLUS_ONE : MAX_SQRT_MINUS_ONE,
            ""
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        out = uint256(-(usdcToBtc_ ? a1 : a0));
        if (out < minOut_) revert TooLittleOut(out, minOut_);
    }

    /// @notice Uniswap v3 swap callback: pay what the pool is owed.
    function uniswapV3SwapCallback(int256 amount0Delta_, int256 amount1Delta_, bytes calldata) external {
        if (msg.sender != address(POOL)) revert NotPool(msg.sender);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount0Delta_ > 0 && !IERC20(USDC).transfer(msg.sender, uint256(amount0Delta_))) revert TransferFailed();
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount1Delta_ > 0 && !IERC20(CBBTC).transfer(msg.sender, uint256(amount1Delta_))) revert TransferFailed();
    }

    function _oracle() internal view returns (bool fresh, uint256 price) {
        (, int256 answer,, uint256 updatedAt,) = ORACLE.latestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        return (answer > 0 && block.timestamp - updatedAt <= MAX_ORACLE_AGE, uint256(answer));
    }

    function _skip(uint256 round_, uint8 action_, uint8 reason_) internal {
        emit Skipped(round_, action_, reason_);
    }

    function setWeekly(uint256 weekly_) external onlyOwner {
        weekly = weekly_;
    }

    function setMonthlyCap(uint256 cap_) external onlyOwner {
        monthlyCap = cap_;
    }

    function setSlippageBps(uint256 bps_) external onlyOwner {
        slippageBps = bps_;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
    }

    /// @notice Withdraw anything (USDC, cbBTC). Resets the budget if USDC leaves.
    function withdraw(address token_, address to_, uint256 amount_) external onlyOwner {
        if (token_ == USDC) budget = 0;
        if (!IERC20(token_).transfer(to_, amount_)) revert TransferFailed();
    }

    function withdrawEth(address payable to_, uint256 amount_) external onlyOwner {
        (bool ok,) = to_.call{ value: amount_ }("");
        if (!ok) revert TransferFailed();
    }
}
