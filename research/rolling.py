"""Reproduce Ballast's README tables: 71 rolling two-year windows of weekly DCA.

Compares plain weekly DCA, Ballast's fear dial (the exact rule in
BallastBrain.multiplierX100) and the Shield trend rule, on Coinbase daily
candles with a 0.5% fee per buy.

    python research/rolling.py
"""
import time
from datetime import datetime, timezone

import backtest as b
from levels import fetch
from signals import ema


def fear_dial(close, ema200):
    """BallastBrain.multiplierX100() / 100."""
    if close < ema200:
        return (100 + min(200, int((ema200 - close) * 500 / ema200))) / 100
    pct = int(close * 100 / ema200)
    if pct <= 130:
        return 1.0
    skim = pct - 130
    return 0.5 if skim >= 50 else (100 - skim) / 100


def window(c, i0, i1, rule, fee=0.005):
    """Return on money invested, max drawdown, money invested, average cost, dollar profit."""
    cash = units = spent = 0.0
    peak = dd = 0.0
    for k, i in enumerate(range(i0, i1)):
        px = c[i][3]
        if rule[0] == "shield":
            if k % 7 == 0:
                cash += 1
                spent += 1
            if rule[1][i - 1] == 1 and cash > 0:
                units += cash * (1 - fee) / px
                cash = 0.0
            elif rule[1][i - 1] == 0 and units > 0:
                cash += units * px * (1 - fee)
                units = 0.0
        elif k % 7 == 0:
            amt = rule[1](i - 1)
            spent += amt
            units += amt * (1 - fee) / px
        val = (cash + units * c[i][4]) / spent
        peak = max(peak, val)
        dd = max(dd, 1 - val / peak)
    final = cash + units * c[i1 - 1][4]
    return final / spent - 1, dd, spent, (spent / units if units else 0), final - spent


def main():
    now = int(time.time())
    for prod in ("BTC-USD", "ETH-USD"):
        c = fetch(prod, 86400, b.START - 400 * 86400, now)
        cl = [x[4] for x in c]
        e200 = ema(cl, 200)
        rules = {
            "plain": ("dca", lambda i: 1),
            "fear dial": ("dca", lambda i: fear_dial(cl[i], e200[i])),
            "shield (no stop)": ("shield", b.s_trend_ema(c)),
        }
        starts = [i for i in range(len(c)) if c[i][0] >= b.START and i + 730 < len(c)
                  and datetime.fromtimestamp(c[i][0], timezone.utc).day == 1]
        n = len(starts)
        res = {k: [window(c, i0, i0 + 730, r) for i0 in starts] for k, r in rules.items()}
        print(f"=== {prod}: {n} two-year windows")
        for k, v in res.items():
            r = sorted(x[0] for x in v)
            beats = sum(v[j][0] > res["plain"][j][0] for j in range(n))
            more = sum(v[j][4] > res["plain"][j][4] for j in range(n))
            spend = sum(x[2] for x in v) / sum(x[2] for x in res["plain"])
            print(f"  {k:17s} median {r[n // 2]:5.0%}  worst {r[0]:5.0%}  P(loss) {sum(x < 0 for x in r) / n:4.0%}  "
                  f"avg maxDD {sum(x[1] for x in v) / n:4.0%}  beats plain {beats:2d}/{n}  "
                  f"more $ {more:2d}/{n}  spend x{spend:.2f}")


if __name__ == "__main__":
    main()
