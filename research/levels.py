"""Volume profile (POC / VAH / VAL, naked POCs) and VWAPs from Coinbase public candles."""
import json, time, urllib.request
from datetime import datetime, timezone, timedelta

API = "https://api.exchange.coinbase.com/products/{p}/candles?granularity={g}&start={s}&end={e}"


def fetch(product, gran, start, end):
    out, t = {}, start
    while t < end:
        t2 = min(t + gran * 300, end)
        url = API.format(p=product, g=gran, s=t, e=t2)
        req = urllib.request.Request(url, headers={"User-Agent": "levels"})
        for _ in range(3):
            try:
                rows = json.load(urllib.request.urlopen(req, timeout=20))
                break
            except Exception:
                time.sleep(1)
        for ts, lo, hi, op, cl, vol in rows:
            out[ts] = (ts, lo, hi, op, cl, vol)
        t = t2
        time.sleep(0.15)
    return sorted(out.values())


def profile(candles, step):
    bins = {}
    for ts, lo, hi, op, cl, vol in candles:
        a, b = int(lo // step), int(hi // step)
        n = b - a + 1
        for k in range(a, b + 1):
            bins[k] = bins.get(k, 0) + vol / n
    if not bins:
        return None
    keys = sorted(bins)
    poc = max(keys, key=lambda k: bins[k])
    total, acc = sum(bins.values()), bins[poc]
    lo_k = hi_k = poc
    while acc < 0.7 * total:
        up = bins.get(hi_k + 1, 0) if hi_k + 1 <= keys[-1] else -1
        dn = bins.get(lo_k - 1, 0) if lo_k - 1 >= keys[0] else -1
        if up < 0 and dn < 0:
            break
        if up >= dn:
            hi_k += 1; acc += max(up, 0)
        else:
            lo_k -= 1; acc += max(dn, 0)
    mid = lambda k: (k + 0.5) * step
    return {"poc": mid(poc), "vah": (hi_k + 1) * step, "val": lo_k * step}


def vwap(candles):
    pv = sum((h + l + c) / 3 * v for _, l, h, o, c, v in candles)
    vol = sum(v for *_, v in candles)
    if not vol:
        return None, None
    vw = pv / vol
    var = sum(v * ((h + l + c) / 3 - vw) ** 2 for _, l, h, o, c, v in candles) / vol
    return vw, var ** 0.5


def ts(d):
    return int(d.replace(tzinfo=timezone.utc).timestamp())


def touched(after, price):
    return any(l <= price <= h for _, l, h, *_ in after)


def run(product, step):
    now = int(time.time())
    h1 = fetch(product, 3600, ts(datetime(2026, 7, 1)), now)
    m15 = fetch(product, 900, ts(datetime(2026, 10, 5)), now)
    m5 = fetch(product, 300, ts(datetime(2026, 11, 16)), now)
    last = h1[-1][4]
    print(f"\n=== {product}  last {last:,.2f}  (1h candles {len(h1)}, 15m {len(m15)}, 5m {len(m5)})")

    def periods(kind):
        res = []
        if kind == "M":
            for y, m in [(2026, 8), (2026, 9), (2026, 10), (2026, 11)]:
                s = datetime(y, m, 1)
                e = datetime(y + (m == 12), m % 12 + 1, 1)
                res.append((s.strftime("%b"), ts(s), ts(e), h1))
        elif kind == "W":
            mon = datetime(2026, 11, 23)
            for i in range(6, -1, -1):
                s = mon - timedelta(weeks=i)
                res.append(("wk " + s.strftime("%b %d"), ts(s), ts(s + timedelta(weeks=1)), m15))
        else:
            today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0, tzinfo=None)
            for i in range(9, -1, -1):
                s = today - timedelta(days=i)
                res.append((s.strftime("%b %d"), ts(s), ts(s + timedelta(days=1)), m5))
        return res

    for kind, name in [("M", "MONTHLY"), ("W", "WEEKLY"), ("D", "DAILY")]:
        print(f"-- {name}  (period: VAL / POC / VAH / VWAP; naked = POC untouched since period end)")
        for label, s, e, data in periods(kind):
            c = [x for x in data if s <= x[0] < e]
            p = profile(c, step)
            vw, sd = vwap(c)
            if not p:
                continue
            after = [x for x in h1 if x[0] >= e] if e <= now else []
            live = e > now
            naked = "" if live else ("  NAKED" if not touched(after, p["poc"]) else "")
            tag = " (developing)" if live else ""
            print(f"  {label:10s} VAL {p['val']:>10,.2f}  POC {p['poc']:>10,.2f}  VAH {p['vah']:>10,.2f}  VWAP {vw:>10,.2f}{tag}{naked}")

    # anchored VWAPs from the 60-day swing high and low
    recent = [x for x in h1 if x[0] >= now - 60 * 86400]
    hi = max(recent, key=lambda x: x[2]); lo = min(recent, key=lambda x: x[1])
    for name, anchor in [("swing high", hi), ("swing low", lo)]:
        seg = [x for x in h1 if x[0] >= anchor[0]]
        vw, sd = vwap(seg)
        price = anchor[2] if name == "swing high" else anchor[1]
        when = datetime.fromtimestamp(anchor[0], timezone.utc).strftime("%b %d %H:%M")
        print(f"-- AVWAP from {name} {price:,.2f} ({when} UTC): {vw:,.2f}  (+/-1sd {vw-sd:,.2f} / {vw+sd:,.2f})")
    for label, s in [("current week", ts(datetime(2026, 11, 23))), ("current month", ts(datetime(2026, 11, 1)))]:
        vw, sd = vwap([x for x in m15 if x[0] >= s])
        print(f"-- VWAP {label}: {vw:,.2f}  bands -1sd {vw-sd:,.2f} / -2sd {vw-2*sd:,.2f} / +1sd {vw+sd:,.2f}")


if __name__ == "__main__":
    run("BTC-USD", 50)
    run("ETH-USD", 2)
