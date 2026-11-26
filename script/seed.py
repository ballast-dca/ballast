"""Compute SteadyBrain.seed() arguments from Coinbase BTC-USD daily candles.

EMA20/50/200 (seeded from the first close, then standard EMA) and Wilder
ATR14 over completed UTC days only, in 8-decimal feed units, matching what
SteadyBrain computes on-chain from the Chainlink feed afterwards.

    python script/seed.py
"""
import json
import time
import urllib.request

API = "https://api.exchange.coinbase.com/products/BTC-USD/candles?granularity=86400&start={s}&end={e}"


def candles(days=420):
    now = int(time.time())
    out, t = {}, now - days * 86400
    while t < now:
        t2 = min(t + 300 * 86400, now)
        req = urllib.request.Request(API.format(s=t, e=t2), headers={"User-Agent": "steady-seed"})
        for ts, lo, hi, op, cl, vol in json.load(urllib.request.urlopen(req, timeout=20)):
            out[ts] = (ts, lo, hi, op, cl)
        t = t2
        time.sleep(0.2)
    return sorted(out.values())


def main():
    today = int(time.time()) // 86400
    c = [x for x in candles() if x[0] // 86400 < today]
    closes = [x[4] for x in c]
    emas = {}
    for n in (20, 50, 200):
        e = closes[0]
        for x in closes[1:]:
            e += (x - e) * 2 / (n + 1)
        emas[n] = e
    atr = None
    for i in range(1, len(c)):
        tr = max(c[i][2] - c[i][1], abs(c[i][2] - c[i - 1][4]), abs(c[i][1] - c[i - 1][4]))
        atr = tr if atr is None else (atr * 13 + tr) / 14
    up = closes[-1] > emas[200] and emas[20] > emas[50]
    print(f"{len(c)} days, close {closes[-1]:,.2f}, EMA20 {emas[20]:,.2f}, EMA50 {emas[50]:,.2f}, "
          f"EMA200 {emas[200]:,.2f}, ATR14 {atr:,.2f}, regime {'UP' if up else 'DOWN'}")
    e8 = lambda v: str(round(v * 1e8))
    print("SEED_ARGS=" + " ".join([str(today), e8(closes[-1]), e8(emas[20]), e8(emas[50]), e8(emas[200]), e8(atr)]))


if __name__ == "__main__":
    main()
