"""Day-1 probe: N bare origin -> Lasna react() -> callback runs. Stdlib + cast only.
usage: python scripts/probe_latency.py base|uni N
"""
import csv, json, os, statistics, subprocess, sys, time, urllib.request

RPC = {"base": "https://sepolia.base.org", "uni": "https://sepolia.unichain.org"}
LASNA = "https://lasna-rpc.rnk.dev/"
PING = "0xde588cd2Ab612A14e27df7D653619eF66CFe0e4d"   # same address on Base and Unichain
DEST = "0xD8167d5b993dfc27a398c74885433bA442795E26"   # ProbeCallback, same on both
RC = "0xde588cd2ab612a14e27df7d653619ef66cfe0e4d"     # ProbeReactive on Lasna
CB_REQ = "0xef94dbc611c4b95bf4b8ba34b413972180c2faf26fbb480befacedd83e07b133"
PONGED = None

def rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"Content-Type": "application/json", "User-Agent": "omni-probe"})
    r = json.load(urllib.request.urlopen(req, timeout=20))
    if "error" in r: raise RuntimeError(r["error"])
    return r["result"]

def block_ms(url, n):
    b = rpc(url, "eth_getBlockByNumber", [hex(n), False])
    return int(b["timestampMs"], 16) if "timestampMs" in b else int(b["timestamp"], 16) * 1000

def main(chain, n):
    global PONGED
    url = RPC[chain]
    PONGED = subprocess.check_output(["cast", "keccak", "Ponged(address,address,uint256,uint256,uint256,uint256,uint256)"], text=True).strip()
    pk = os.environ["DEPLOYER_PRIVATE_KEY"]
    rows = []
    for i in range(n):
        lasna0 = int(rpc(LASNA, "eth_blockNumber", []), 16)
        out = json.loads(subprocess.check_output(["cast", "send", "--rpc-url", url, "--private-key", pk, PING, "ping()", "--json"], text=True))
        ob, otx = int(out["blockNumber"], 16), out["transactionHash"]
        pid = int(out["logs"][0]["topics"][1], 16)
        t_end = time.time() + 120
        dl = None
        while time.time() < t_end and not dl:
            time.sleep(0.5)
            try:  # load-balanced RPCs can lag behind the block the ping landed in
                logs = rpc(url, "eth_getLogs", [{"fromBlock": hex(ob), "address": DEST, "topics": [PONGED, "0x" + format(pid, "064x")]}])
            except RuntimeError:
                continue
            dl = logs[0] if logs else None
        if not dl:
            print(f"run {i} id {pid}: NO CALLBACK in 120 s"); rows.append([chain, pid, otx, ob, "", "", "", "", ""]); continue
        db = int(dl["blockNumber"], 16)
        o_ms, d_ms = block_ms(url, ob), block_ms(url, db)
        # Lasna leg: the system contract's callback-request log whose payload carries this origin block
        ll = rpc(LASNA, "eth_getLogs", [{"fromBlock": hex(lasna0), "address": "0x8888888888888888888888888888888888888888", "topics": [CB_REQ, None, "0x" + "0" * 24 + RC[2:]]}])
        ll = [l for l in ll if format(ob, "x").rjust(64, "0") in l["data"]]
        lb = int(ll[0]["blockNumber"], 16) if ll else None
        l_ms = block_ms(LASNA, lb) if lb else None
        e2e = d_ms - o_ms
        rows.append([chain, pid, otx, ob, lb, ll[0]["transactionHash"] if ll else "", dl["transactionHash"], db, e2e])
        print(f"run {i} id {pid}: origin {ob} -> lasna {lb} -> dest {db}  end-to-end {e2e} ms ({db - ob} blocks)")
        time.sleep(2)
    path = f"results/probe_{chain}.csv"
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.writer(f)
        if new: w.writerow(["chain", "id", "origin_tx", "origin_block", "lasna_block", "lasna_tx", "callback_tx", "callback_block", "end_to_end_ms"])
        w.writerows(rows)
    ok = sorted(r[8] for r in rows if r[8] != "")
    if ok:
        q = statistics.quantiles(ok, n=20) if len(ok) > 1 else [ok[0]] * 19
        print(f"{chain}: {len(ok)}/{n} delivered, p50 {statistics.median(ok):.0f} ms, p95 {q[18]:.0f} ms, min {ok[0]} max {ok[-1]}")

if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]))
