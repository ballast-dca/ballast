"""Reversal indicators (RSI, MACD, divergences) on 1h / 4h / 1d, combined with
volume-profile and VWAP levels from levels.py.

    python tools/trading/signals.py              # BTC-USD and ETH-USD
    python tools/trading/signals.py SOL-USD 0.5  # product and price bin
"""
import sys, time
from datetime import datetime, timezone
from levels import fetch, run as run_levels


def ema(xs, n):
    k, out = 2 / (n + 1), []
    for x in xs:
        out.append(x if not out else out[-1] + k * (x - out[-1]))
    return out


def rsi(closes, n=14):
    out = [None] * len(closes)
    gains = losses = 0.0
    for i in range(1, len(closes)):
        d = closes[i] - closes[i - 1]
        g, l = max(d, 0), max(-d, 0)
        if i <= n:
            gains += g; losses += l
            if i == n:
                gains /= n; losses /= n
                out[i] = 100 - 100 / (1 + gains / losses) if losses else 100
        else:
            gains = (gains * (n - 1) + g) / n
            losses = (losses * (n - 1) + l) / n
            out[i] = 100 - 100 / (1 + gains / losses) if losses else 100
    return out


def macd(closes):
    line = [a - b for a, b in zip(ema(closes, 12), ema(closes, 26))]
    sig = ema(line, 9)
    return line, sig, [a - b for a, b in zip(line, sig)]


def resample(candles, hours):
    """Group 1h candles (ts, low, high, open, close, vol) into UTC buckets."""
    out, size = {}, hours * 3600
    for ts, lo, hi, op, cl, vol in candles:
        k = ts - ts % size
        if k not in out:
            out[k] = [k, lo, hi, op, cl, vol]
        else:
            b = out[k]
            b[1] = min(b[1], lo); b[2] = max(b[2], hi); b[4] = cl; b[5] += vol
    return [tuple(v) for _, v in sorted(out.items())]


def pivots(vals, kind, span=3, lookback=80):
    n, res = len(vals), []
    for i in range(max(span, n - lookback), n - span):
        win = vals[i - span:i + span + 1]
        if (kind == "low" and vals[i] == min(win)) or (kind == "high" and vals[i] == max(win)):
            res.append(i)
    return res


def divergence(candles, r):
    lows = [c[1] for c in candles]
    highs = [c[2] for c in candles]
    found = []
    pl = [i for i in pivots(lows, "low") if r[i] is not None]
    if len(pl) >= 2:
        a, b = pl[-2], pl[-1]
        if lows[b] < lows[a] and r[b] > r[a]:
            found.append(f"BULLISH div: low {lows[a]:,.2f}->{lows[b]:,.2f}, RSI {r[a]:.0f}->{r[b]:.0f}")
        elif lows[b] > lows[a] and r[b] < r[a]:
            found.append(f"hidden bullish div: higher low, RSI {r[a]:.0f}->{r[b]:.0f}")
    ph = [i for i in pivots(highs, "high") if r[i] is not None]
    if len(ph) >= 2:
        a, b = ph[-2], ph[-1]
        if highs[b] > highs[a] and r[b] < r[a]:
            found.append(f"BEARISH div: high {highs[a]:,.2f}->{highs[b]:,.2f}, RSI {r[a]:.0f}->{r[b]:.0f}")
        elif highs[b] < highs[a] and r[b] > r[a]:
            found.append(f"hidden bearish div: lower high, RSI {r[a]:.0f}->{r[b]:.0f}")
    return found


def read(candles, label):
    closes = [c[4] for c in candles]
    r = rsi(closes)
    line, sig, hist = macd(closes)
    e20, e50, e200 = ema(closes, 20)[-1], ema(closes, 50)[-1], ema(closes, 200)[-1]
    cross = ""
    for back in range(1, 6):
        if hist[-back] > 0 >= hist[-back - 1]:
            cross = f"bull cross {back - 1} bars ago"; break
        if hist[-back] < 0 <= hist[-back - 1]:
            cross = f"bear cross {back - 1} bars ago"; break
    slope = "rising" if hist[-1] > hist[-2] else "falling"
    zone = "OVERSOLD" if r[-1] < 30 else "OVERBOUGHT" if r[-1] > 70 else ""
    print(f"  {label:3s} RSI {r[-1]:5.1f} {zone:10s} MACD hist {hist[-1]:+9.2f} ({slope}{', ' + cross if cross else ''})"
          f"  line {'>' if line[-1] > 0 else '<'} 0   EMA20 {e20:,.2f}  EMA50 {e50:,.2f}  EMA200 {e200:,.2f}")
    for d in divergence(candles, r):
        print(f"       {d}")


def run(product, step):
    run_levels(product, step)
    now = int(time.time())
    h1 = fetch(product, 3600, now - 120 * 86400, now)
    d1 = fetch(product, 86400, now - 300 * 86400, now)
    print(f"-- INDICATORS {product} (last candle may be incomplete)")
    read(h1, "1h")
    read(resample(h1, 4), "4h")
    read(d1, "1d")


if __name__ == "__main__":
    print(datetime.now(timezone.utc).strftime("as of %Y-%m-%d %H:%M UTC"))
    if len(sys.argv) > 2:
        run(sys.argv[1], float(sys.argv[2]))
    else:
        run("BTC-USD", 50)
        run("ETH-USD", 2)
