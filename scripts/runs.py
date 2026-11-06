"""Closed-loop runs against the live deployment. Stdlib + Foundry's cast.

  python scripts/runs.py catch N      N gaps, alternating chain and direction; both legs should fill
  python scripts/runs.py unwind N     a gap plus a "competitor" that closes the other side first;
                                      one leg skips, the filled leg is unwound
  python scripts/runs.py control N    sub-fee gaps; nothing may fire

Every run appends one JSON line to results/runs.jsonl with all tx hashes and timings.
"""
import json, os, statistics, subprocess, sys, time, urllib.request

D = json.load(open("deployments.json"))
RPC = {84532: "https://sepolia.base.org", 1301: "https://sepolia.unichain.org", 5318007: "https://lasna-rpc.rnk.dev/"}
NAME = {84532: "base", 1301: "unichain"}
GC = D["lasna"]["gapCatcher"]
EX = {84532: D["base"]["executor"], 1301: D["unichain"]["executor"]}
GM = {84532: D["base"]["gapMaker"], 1301: D["unichain"]["gapMaker"]}
T = {k: subprocess.check_output(["cast", "keccak", s], text=True).strip() for k, s in {
    "filled": "Filled(uint256,bool,uint256,uint256,uint160,uint256,uint256)",
    "skipped": "Skipped(uint256,uint8,uint160,uint256,uint256)",
    "requested": "Requested(uint256,uint256,uint256,uint256,uint160,uint160,uint160)",
    "unwinding": "Unwinding(uint256,uint256,uint256)",
    "released": "Released(uint256,uint8)"}.items()}
OUTCOME = {1: "both_filled", 2: "both_skipped", 3: "unwound", 4: "timed_out"}
SKIP = {1: "late", 2: "gone", 3: "failed"}
PK = os.environ["DEPLOYER_PRIVATE_KEY"]


def rpc(chain, method, params, tries=5):
    for i in range(tries):
        try:
            req = urllib.request.Request(RPC[chain], json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                         {"Content-Type": "application/json", "User-Agent": "omni-runs"})
            r = json.load(urllib.request.urlopen(req, timeout=20))
            if "error" in r: raise RuntimeError(r["error"])
            return r["result"]
        except Exception:
            if i == tries - 1: raise
            time.sleep(1)


def head(chain):
    return int(rpc(chain, "eth_blockNumber", []), 16)


def block_ms(chain, n):
    b = rpc(chain, "eth_getBlockByNumber", [hex(n), False])
    return int(b["timestampMs"], 16) if "timestampMs" in b else int(b["timestamp"], 16) * 1000


def logs(chain, addr, frm, topics=None):
    q = {"fromBlock": hex(frm), "address": addr}
    if topics: q["topics"] = topics
    return rpc(chain, "eth_getLogs", [q])


def words(data):
    d = data[2:]
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]


def gap(chain, zero_for_one, amount, wait=True):
    args = ["cast", "send", "--rpc-url", RPC[chain], "--private-key", PK, GM[chain], "makeGap(bool,uint256)",
            "true" if zero_for_one else "false", str(amount)]
    for _ in range(4):  # load-balanced RPCs can serve a stale nonce
        p = subprocess.run(args + (["--json"] if wait else ["--async"]), capture_output=True, text=True)
        if p.returncode == 0: break
        time.sleep(2)
    else:
        raise RuntimeError(p.stderr)
    if not wait: return p.stdout.strip()
    r = json.loads(p.stdout)
    return r["transactionHash"]


def receipt(chain, tx):
    for _ in range(60):
        r = rpc(chain, "eth_getTransactionReceipt", [tx])
        if r: return r
        time.sleep(0.5)
    raise RuntimeError(f"no receipt {tx}")


def run(kind, chain, zero_for_one, amount):
    other = 1301 if chain == 84532 else 84532
    start = {c: head(c) for c in (84532, 1301, 5318007)}
    if kind == "unwind":  # both swaps go out at once; whichever Lasna sees first opens the catch
        txs = {chain: gap(chain, zero_for_one, amount, wait=False), other: gap(other, zero_for_one, amount, wait=False)}
    else:
        txs = {chain: gap(chain, zero_for_one, amount, wait=False)}
    rcpt = {c: receipt(c, tx) for c, tx in txs.items()}
    row = {"kind": kind, "gap_chain": NAME[chain], "zero_for_one": zero_for_one, "amount": amount,
           "gap_txs": {NAME[c]: tx for c, tx in txs.items()}, "gap_blocks": {NAME[c]: int(r["blockNumber"], 16) for c, r in rcpt.items()}}
    # wait for the release (or, for a control, make sure nothing is requested)
    t_end = time.time() + (20 if kind == "control" else 120)
    req = rel = None
    while time.time() < t_end:
        time.sleep(1)
        L = logs(5318007, GC, start[5318007])
        req = next((l for l in L if l["topics"][0] == T["requested"]), None)
        rel = next((l for l in L if l["topics"][0] == T["released"]), None)
        if rel or (kind == "control" and req): break
    if kind == "control":
        row["fired"] = req is not None
        print(f"control {NAME[chain]} {amount / 1e18:g}: {'FIRED (bad)' if req else 'no fire (good)'}")
        return row
    if not req:
        row["error"] = "no Requested on Lasna"; print(row["error"]); return row
    rid = int(req["topics"][1], 16)
    w = words(req["data"])
    origin_chain, origin_block = w[0], w[1]
    o_ms = block_ms(origin_chain, origin_block)
    row.update({"id": rid, "origin": {"chain": NAME[origin_chain], "block": origin_block, "tx": "0x%064x" % w[2]},
                "lasna_request_tx": req["transactionHash"], "lasna_request_block": int(req["blockNumber"], 16)})
    if rel:
        row.update({"outcome": OUTCOME[words(rel["data"])[0]], "lasna_release_tx": rel["transactionHash"]})
    legs = []
    for c in (84532, 1301):
        for l in logs(c, EX[c], start[c], [None, "0x%064x" % rid]):
            b = int(l["blockNumber"], 16)
            w = words(l["data"])
            leg = {"chain": NAME[c], "tx": l["transactionHash"], "block": b, "ms_after_origin": block_ms(c, b) - o_ms}
            if l["topics"][0] == T["filled"]:
                leg.update({"result": "filled", "zero_for_one": bool(w[0]), "in": w[1] / 1e18, "out": w[2] / 1e18})
            else:
                leg.update({"result": "skipped:" + SKIP.get(w[0], str(w[0]))})
            legs.append(leg)
    row["legs"] = legs
    print(f"{kind} #{rid} gap on {NAME[chain]} -> origin {row['origin']['chain']}: {row.get('outcome', 'NOT RELEASED')}; "
          + ", ".join(f"{l['chain']} {l['result']} +{l['ms_after_origin']} ms" for l in legs))
    return row


def main(kind, n):
    rows = []
    amount = 1 * 10**18 if kind == "control" else 20 * 10**18
    for i in range(n):
        chain = 84532 if i % 2 == 0 else 1301
        zero_for_one = (i // 2) % 2 == 0  # base sell, uni sell, base buy, uni buy: inventory stays balanced
        row = run(kind, chain, zero_for_one, amount)
        row["ts"] = int(time.time())
        rows.append(row)
        with open("results/runs.jsonl", "a") as f:
            f.write(json.dumps(row) + "\n")
        time.sleep(7)  # Lasna cooldown is 5 s
    if kind == "catch":
        both = [r for r in rows if r.get("outcome") == "both_filled"]
        last = [max(l["ms_after_origin"] for l in r["legs"]) for r in both]
        if last:
            q = statistics.quantiles(last, n=10) if len(last) > 1 else [last[0]] * 9
            print(f"{len(both)}/{n} both filled; gap -> both legs filled: p50 {statistics.median(last):.0f} ms, p90 {q[8]:.0f} ms")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]))
