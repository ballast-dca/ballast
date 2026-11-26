"""Swing-trading backtester for BTC/ETH spot on Coinbase candles.

Long-only, all-in or all-out. Signals are computed on a bar's close and filled
at the next bar's open (no look-ahead). Fees are charged on both sides.
Standard parameters only; results are split in-sample / out-of-sample so a
rule is judged on data it was not shaped on.

    python tools/trading/backtest.py                  # BTC + ETH, daily
    python tools/trading/backtest.py --gran 21600     # 6h bars
    python tools/trading/backtest.py --fee 0.009      # taker fees
"""
import argparse
import math
import time
from datetime import datetime, timezone

from levels import fetch
from signals import ema, rsi

SPLIT = int(datetime(2024, 1, 1, tzinfo=timezone.utc).timestamp())
START = int(datetime(2019, 1, 1, tzinfo=timezone.utc).timestamp())


def sma(xs, n):
    out, s = [], 0.0
    for i, x in enumerate(xs):
        s += x
        if i >= n:
            s -= xs[i - n]
        out.append(s / n if i >= n - 1 else None)
    return out


def rolling(xs, n, f):
    return [f(xs[i - n + 1:i + 1]) if i >= n - 1 else None for i in range(len(xs))]


# ---- strategies: return a list of desired positions (1 long, 0 flat) per bar ----

def s_trend_ema(c):
    """Long while close > EMA200 and EMA20 > EMA50 (trend + momentum)."""
    cl = [x[4] for x in c]
    e20, e50, e200 = ema(cl, 20), ema(cl, 50), ema(cl, 200)
    return [1 if i >= 200 and cl[i] > e200[i] and e20[i] > e50[i] else 0 for i in range(len(c))]


def s_rsi_regime(c):
    """Long while daily RSI14 >= 50 and close > EMA200 (a simple regime filter)."""
    cl = [x[4] for x in c]
    r, e200 = rsi(cl), ema(cl, 200)
    return [1 if i >= 200 and r[i] is not None and r[i] >= 50 and cl[i] > e200[i] else 0 for i in range(len(c))]


def s_donchian(c):
    """Turtle-style: enter on a 20-bar high, exit on a 10-bar low."""
    hi = rolling([x[2] for x in c], 20, max)
    lo = rolling([x[1] for x in c], 10, min)
    pos, out = 0, []
    for i in range(len(c)):
        if i >= 21:
            if pos == 0 and c[i][4] > hi[i - 1]:
                pos = 1
            elif pos == 1 and c[i][4] < lo[i - 1]:
                pos = 0
        out.append(pos)
    return out


def s_pullback(c):
    """Buy dips in an uptrend: close > EMA200 and RSI2 < 10; exit when RSI2 > 70 or close < EMA200."""
    cl = [x[4] for x in c]
    r2, e200 = rsi(cl, 2), ema(cl, 200)
    pos, out = 0, []
    for i in range(len(c)):
        if i >= 200 and r2[i] is not None:
            if pos == 0 and cl[i] > e200[i] and r2[i] < 10:
                pos = 1
            elif pos == 1 and (r2[i] > 70 or cl[i] < e200[i]):
                pos = 0
        out.append(pos)
    return out


def s_oversold_any(c):
    """Counter-trend control: buy RSI14 < 30 with no trend filter, sell RSI14 > 55."""
    cl = [x[4] for x in c]
    r = rsi(cl)
    pos, out = 0, []
    for i in range(len(c)):
        if r[i] is not None:
            if pos == 0 and r[i] < 30:
                pos = 1
            elif pos == 1 and r[i] > 55:
                pos = 0
        out.append(pos)
    return out


def s_macd_trend(c):
    """MACD line above signal while close > EMA200."""
    cl = [x[4] for x in c]
    e12, e26, e200 = ema(cl, 12), ema(cl, 26), ema(cl, 200)
    line = [a - b for a, b in zip(e12, e26)]
    sig = ema(line, 9)
    return [1 if i >= 200 and line[i] > sig[i] and cl[i] > e200[i] else 0 for i in range(len(c))]


def s_golden_cross(c):
    """SMA50 above SMA200."""
    cl = [x[4] for x in c]
    s50, s200 = sma(cl, 50), sma(cl, 200)
    return [1 if s200[i] is not None and s50[i] > s200[i] else 0 for i in range(len(c))]


def trend_score(c):
    """Custom indicator, 0 to 100: 25 points each for close > EMA200, EMA20 > EMA50,
    RSI14 > 50, and close > 20-bar VWAP."""
    cl = [x[4] for x in c]
    e20, e50, e200, r = ema(cl, 20), ema(cl, 50), ema(cl, 200), rsi(cl)
    out = []
    for i in range(len(c)):
        if i < 200 or r[i] is None:
            out.append(None)
            continue
        win = c[i - 19:i + 1]
        vol = sum(x[5] for x in win) or 1e-12
        vwap = sum((x[2] + x[1] + x[4]) / 3 * x[5] for x in win) / vol
        out.append(25 * ((cl[i] > e200[i]) + (e20[i] > e50[i]) + (r[i] > 50) + (cl[i] > vwap)))
    return out


def s_trend_score(c):
    """Custom: long at score >= 75, flat at score <= 25 (hysteresis)."""
    sc = trend_score(c)
    pos, out = 0, []
    for v in sc:
        if v is not None:
            if pos == 0 and v >= 75:
                pos = 1
            elif pos == 1 and v <= 25:
                pos = 0
        out.append(pos)
    return out


def s_hold(c):
    return [1] * len(c)


STRATEGIES = {
    "buy & hold": s_hold,
    "trend EMA 20/50/200": s_trend_ema,
    "RSI>=50 regime": s_rsi_regime,
    "Donchian 20/10": s_donchian,
    "pullback RSI2": s_pullback,
    "oversold RSI<30 (control)": s_oversold_any,
    "MACD + EMA200": s_macd_trend,
    "golden cross 50/200": s_golden_cross,
    "Trend Score (custom)": s_trend_score,
}


def atr(c, n=14):
    trs = []
    for i, x in enumerate(c):
        pc = c[i - 1][4] if i else x[4]
        trs.append(max(x[2] - x[1], abs(x[2] - pc), abs(x[1] - pc)))
    out, a = [], None
    for i, t in enumerate(trs):
        a = t if a is None else (a * (n - 1) + t) / n
        out.append(a)
    return out


def run_risk(c, want, fee, lo, hi, stop_k=None, tp_k=None, trail_k=None):
    """Like run(), plus exits a Reactive contract would enforce intrabar:
    fixed stop at entry - stop_k*ATR, take-profit at entry + tp_k*ATR, trailing
    stop at highest close - trail_k*ATR. If a bar touches both, assume the stop
    (conservative). After a risk exit, wait for the signal to reset before re-entry."""
    a = atr(c)
    idx = [i for i in range(len(c) - 1) if lo <= c[i + 1][0] < hi]
    if not idx:
        return None
    cash, units, pos, trades, wins, entry_val = 1.0, 0.0, 0, 0, 0, 0.0
    peak, dd, exposure, curve = 1.0, 0.0, 0, []
    stop = tp = hi_close = None
    blocked = False
    for i in idx:
        bar = c[i + 1]
        if want[i] == 0:
            blocked = False
        target = 0 if blocked else want[i]
        if target != pos:
            px = bar[3]
            if target == 1:
                f = cash * fee
                units, entry_val, cash = (cash - f) / px, cash, 0.0
                stop = px - stop_k * a[i] if stop_k else None
                tp = px + tp_k * a[i] if tp_k else None
                hi_close = px
            else:
                gross = units * px
                cash, units = gross * (1 - fee), 0.0
                trades += 1
                wins += cash > entry_val
            pos = target
        if pos == 1:
            if trail_k:
                hi_close = max(hi_close, bar[4])
                tstop = hi_close - trail_k * a[i]
                stop = max(stop, tstop) if stop else tstop
            exit_px = None
            if stop and bar[1] <= stop:
                exit_px = min(stop, bar[3])
            elif tp and bar[2] >= tp:
                exit_px = max(tp, bar[3])
            if exit_px:
                gross = units * exit_px
                cash, units, pos = gross * (1 - fee), 0.0, 0
                trades += 1
                wins += cash > entry_val
                blocked = True
        eq = cash + units * bar[4]
        exposure += pos
        peak = max(peak, eq)
        dd = max(dd, 1 - eq / peak)
        curve.append(eq)
    eq = curve[-1]
    years = (c[idx[-1] + 1][0] - c[idx[0] + 1][0]) / (365.25 * 86400)
    rets = [curve[k] / curve[k - 1] - 1 for k in range(1, len(curve))]
    mu = sum(rets) / len(rets)
    sd = math.sqrt(sum((r - mu) ** 2 for r in rets) / len(rets)) or 1e-12
    return {"ret": eq - 1, "dd": dd, "sharpe": mu / sd * math.sqrt(len(rets) / years),
            "trades": trades, "win": wins / trades if trades else 0, "expo": exposure / len(idx)}


OVERLAYS = {
    "no stops": {},
    "stop 2ATR": {"stop_k": 2},
    "stop 2ATR + TP 4ATR": {"stop_k": 2, "tp_k": 4},
    "trail 3ATR": {"trail_k": 3},
    "stop 2ATR + trail 3ATR": {"stop_k": 2, "trail_k": 3},
}


def risk_report(prods, fee, gran):
    now = int(time.time())
    for prod in prods:
        c = fetch(prod, gran, START - 250 * gran, now)
        print(f"=== {prod} risk overlays, OOS 2024-now (IS in brackets)")
        print(f"{'strategy':24s} {'overlay':24s} {'OOS ret':>8s} {'maxDD':>6s} {'Sharpe':>6s} "
              f"{'trades':>6s} {'win':>5s} {'IS ret':>9s}")
        for name, fn in STRATEGIES.items():
            if name == "buy & hold":
                continue
            want = fn(c)
            for oname, kw in OVERLAYS.items():
                o = run_risk(c, want, fee, SPLIT, now + 1, **kw)
                s = run_risk(c, want, fee, START, SPLIT, **kw)
                print(f"{name:24s} {oname:24s} {o['ret']:8.0%} {o['dd']:6.0%} {o['sharpe']:6.2f} "
                      f"{o['trades']:6d} {o['win']:5.0%} {'(' + format(s['ret'], '.0%') + ')':>9s}")
        print()


def run(c, want, fee, lo, hi):
    """Simulate on bars with lo <= ts < hi. Fill at next bar's open."""
    idx = [i for i in range(len(c) - 1) if lo <= c[i + 1][0] < hi]
    if not idx:
        return None
    cash, units, pos, trades, fees, peak, dd = 1.0, 0.0, 0, 0, 0.0, 1.0, 0.0
    exposure, wins, entry_val, curve = 0, 0, 0.0, []
    for i in idx:
        px = c[i + 1][3]                      # next bar's open
        if want[i] != pos:
            if want[i] == 1:
                f = cash * fee
                units, entry_val = (cash - f) / px, cash
                cash, fees = 0.0, fees + f
            else:
                gross = units * px
                f = gross * fee
                cash, units, fees = gross - f, 0.0, fees + f
                trades += 1
                wins += cash > entry_val
            pos = want[i]
        eq = cash + units * c[i + 1][4]
        exposure += pos
        peak = max(peak, eq)
        dd = max(dd, 1 - eq / peak)
        curve.append(eq)
    eq = curve[-1]
    years = (c[idx[-1] + 1][0] - c[idx[0] + 1][0]) / (365.25 * 86400)
    rets = [curve[k] / curve[k - 1] - 1 for k in range(1, len(curve))]
    mu = sum(rets) / len(rets)
    sd = math.sqrt(sum((r - mu) ** 2 for r in rets) / len(rets)) or 1e-12
    per_year = len(rets) / years if years else 365
    return {
        "ret": eq - 1, "cagr": eq ** (1 / years) - 1 if years > 0 else 0, "dd": dd,
        "sharpe": mu / sd * math.sqrt(per_year), "trades": trades,
        "win": wins / trades if trades else 0, "fees": fees, "expo": exposure / len(idx),
    }


def dca(c, fee, lo, hi, every_days=7):
    """Buy a fixed amount every N days; return multiple on money invested and max drawdown of the position."""
    bars = [x for x in c if lo <= x[0] < hi]
    if not bars:
        return None
    step = max(1, round(every_days * 86400 / (bars[1][0] - bars[0][0])))
    units = spent = 0.0
    peak, dd = 0.0, 0.0
    for k, b in enumerate(bars):
        if k % step == 0:
            units += (1 - fee) / b[3]
            spent += 1
        val = units * b[4] / spent
        peak = max(peak, val)
        dd = max(dd, 1 - val / peak)
    return units * bars[-1][4] / spent - 1, dd


def gated_dca(c, want, fee, lo, hi, sell=False, every_days=7):
    """Weekly contribution of 1. Buy (with all idle cash) only while want == 1.
    sell=True also exits to cash when want turns 0. Returns gain on money invested and max drawdown."""
    idx = [i for i in range(len(c) - 1) if lo <= c[i + 1][0] < hi]
    if not idx:
        return None
    step = max(1, round(every_days * 86400 / (c[1][0] - c[0][0])))
    cash = units = spent = 0.0
    peak = dd = 0.0
    for k, i in enumerate(idx):
        px = c[i + 1][3]
        if k % step == 0:
            cash += 1
            spent += 1
        if want[i] == 1 and cash > 0:
            units += cash * (1 - fee) / px
            cash = 0.0
        elif sell and want[i] == 0 and units > 0:
            cash += units * px * (1 - fee)
            units = 0.0
        val = (cash + units * c[i + 1][4]) / spent
        peak = max(peak, val)
        dd = max(dd, 1 - val / peak)
    return (cash + units * c[idx[-1] + 1][4]) / spent - 1, dd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gran", type=int, default=86400)
    ap.add_argument("--fee", type=float, default=0.005)
    ap.add_argument("--products", default="BTC-USD,ETH-USD")
    ap.add_argument("--risk", action="store_true", help="compare stop-loss / take-profit overlays")
    a = ap.parse_args()
    if a.risk:
        risk_report(a.products.split(","), a.fee, a.gran)
        return
    now = int(time.time())
    print(f"fee {a.fee:.2%} per side, bars {a.gran // 3600}h, in-sample 2019-2023, out-of-sample 2024-now\n")
    for prod in a.products.split(","):
        c = fetch(prod, a.gran, START - 250 * a.gran, now)
        print(f"=== {prod}  ({len(c)} bars)")
        print(f"{'strategy':28s} {'period':5s} {'return':>8s} {'CAGR':>7s} {'maxDD':>6s} {'Sharpe':>6s} "
              f"{'trades':>6s} {'win':>5s} {'in mkt':>6s}")
        for name, fn in STRATEGIES.items():
            want = fn(c)
            for label, lo, hi in (("IS", START, SPLIT), ("OOS", SPLIT, now + 1)):
                r = run(c, want, a.fee, lo, hi)
                if r:
                    print(f"{name:28s} {label:5s} {r['ret']:8.0%} {r['cagr']:7.0%} {r['dd']:6.0%} "
                          f"{r['sharpe']:6.2f} {r['trades']:6d} {r['win']:5.0%} {r['expo']:6.0%}")
        for label, lo, hi in (("IS", START, SPLIT), ("OOS", SPLIT, now + 1)):
            d = dca(c, a.fee, lo, hi)
            if d:
                print(f"{'weekly DCA (on $ invested)':28s} {label:5s} {d[0]:8.0%} {'':>7s} {d[1]:6.0%}")
        trend = s_trend_ema(c)
        for name, sell in (("trend-gated DCA (hold)", False), ("trend-gated DCA (sell)", True)):
            for label, lo, hi in (("IS", START, SPLIT), ("OOS", SPLIT, now + 1)):
                d = gated_dca(c, trend, a.fee, lo, hi, sell=sell)
                if d:
                    print(f"{name:28s} {label:5s} {d[0]:8.0%} {'':>7s} {d[1]:6.0%}")
        print()


if __name__ == "__main__":
    main()
