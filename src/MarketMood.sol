// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// MarketMood: a public, on-chain read of BTC's long-term trend on Base.
//
// Written once a day by SteadyBrain on Reactive Network from the Chainlink
// BTC/USD feed. Any contract can read it, for example to tighten risk limits
// when the market is in fear, or to pause a strategy in a downtrend:
//
//     (, , , , , , int256 distanceBps, bool up, , ) = MarketMood(addr).latest();
//     if (distanceBps < -2000) { /* BTC more than 20% below its 200-day average */ }
//
// Prices are in Chainlink's 8-decimal units.

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

contract MarketMood is AbstractCallback {
    struct Mood {
        uint256 day;            // UTC day (timestamp / 86400) of the close
        uint256 close;          // daily close
        uint256 ema20;
        uint256 ema50;
        uint256 ema200;         // the 200-day average
        uint256 atr;            // 14-day average true range
        int256 distanceBps;     // (close - ema200) / ema200, in basis points
        bool up;                // close > EMA200 and EMA20 > EMA50
        uint256 multiplierX100; // Steady's fear dial for the coming week
        uint256 updatedAt;
    }

    event MoodUpdated(uint256 indexed day_, uint256 close_, int256 distanceBps_, bool up_, uint256 multiplierX100_);

    Mood internal _mood;

    // `payable` so the contract can be funded at deployment (callback fees on Base).
    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
    }

    /// @notice Entry point for SteadyBrain's daily callback.
    function setMood(
        address rc,
        uint256 day_,
        uint256 close_,
        uint256 ema20_,
        uint256 ema50_,
        uint256 ema200_,
        uint256 atr_,
        int256 distanceBps_,
        bool up_,
        uint256 multiplierX100_
    ) external onlyServiceProvider onlyCallbackSender(rc) {
        if (day_ < _mood.day) return;      // ignore a late duplicate of an older day
        _mood = Mood(day_, close_, ema20_, ema50_, ema200_, atr_, distanceBps_, up_, multiplierX100_,
            block.timestamp);
        emit MoodUpdated(day_, close_, distanceBps_, up_, multiplierX100_);
    }

    function latest() external view returns (Mood memory) {
        return _mood;
    }

    /// @notice True when BTC closed more than `bps` basis points below its 200-day average.
    function inFear(uint256 bps) external view returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return _mood.distanceBps < -int256(bps);
    }
}
