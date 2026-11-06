"""Keeper-bot baseline, run by us and reported as measured, even where it beats Omni.

The bot is what Omni replaces: a process on a laptop with two RPC connections and a hot key.
It polls both pools' slot0 at `latest` over the public RPCs. On a gap it signs both legs locally
and sends them at once, with the same mid-price limit and size rule as the Executor.
It trades a separate twin-pool pair (fee 0.05%, tick spacing 10, same depth) that GapCatcher does not watch.

usage: python scripts/baseline.py N      appends to results/baseline.jsonl
"""
import json, os, statistics, sys, time
from concurrent.futures import ThreadPoolExecutor
from eth_abi import encode
from eth_account import Account
from web3 import Web3

D = json.load(open("deployments.json"))
CH = {
    84532: {"rpc": "https://sepolia.base.org", "router": "0x8B5bcC363ddE2614281aD875bad385E0A785D3B9", "sv": "0x571291b572ed32ce6751a2cb2486ebee8defb9b4"},
    1301: {"rpc": "https://sepolia.unichain.org", "router": "0x9140a78c1a137c7ff1c151ec8231272af78a99a4", "sv": "0xc199f1072a74d4e905aba1a84d9a45e2546b6222"},
}
NAME = {84532: "base", 1301: "unichain"}
ZERO = "0x0000000000000000000000000000000000000000"
KEY = (Web3.to_checksum_address(D["token0"]), Web3.to_checksum_address(D["token1"]), 500, 10, ZERO)
POOL_ID = Web3.keccak(encode(["address", "address", "uint24", "int24", "address"], list(KEY)))
MIN_LIMIT, MAX_LIMIT = 4295128740, 1461446703485210103287273052203988822378723970341
MIN_GAP_SQRT_BPS = 50  # same trigger as GapCatcher
MAX_IN = 50 * 10**18
ROUTER_ABI = [{"name": "swap", "type": "function", "stateMutability": "payable", "outputs": [{"type": "int256"}], "inputs": [
    {"name": "key", "type": "tuple", "components": [{"name": "c0", "type": "address"}, {"name": "c1", "type": "address"}, {"name": "fee", "type": "uint24"}, {"name": "ts", "type": "int24"}, {"name": "hooks", "type": "address"}]},
    {"name": "params", "type": "tuple", "components": [{"name": "zeroForOne", "type": "bool"}, {"name": "amountSpecified", "type": "int256"}, {"name": "sqrtPriceLimitX96", "type": "uint160"}]},
    {"name": "settings", "type": "tuple", "components": [{"name": "takeClaims", "type": "bool"}, {"name": "settleUsingBurn", "type": "bool"}]},
    {"name": "hookData", "type": "bytes"}]}]
SV_ABI = [{"name": "getSlot0", "type": "function", "stateMutability": "view", "inputs": [{"name": "id", "type": "bytes32"}],
           "outputs": [{"type": "uint160"}, {"type": "int24"}, {"type": "uint24"}, {"type": "uint24"}]}]

acct = Account.from_key(os.environ["DEPLOYER_PRIVATE_KEY"])
w3 = {c: Web3(Web3.HTTPProvider(v["rpc"], request_kwargs={"timeout": 10})) for c, v in CH.items()}
router = {c: w3[c].eth.contract(address=Web3.to_checksum_address(v["router"]), abi=ROUTER_ABI) for c, v in CH.items()}
sv = {c: w3[c].eth.contract(address=Web3.to_checksum_address(v["sv"]), abi=SV_ABI) for c, v in CH.items()}
nonce = {c: w3[c].eth.get_transaction_count(acct.address, "pending") for c in CH}
gas_price = {c: w3[c].eth.gas_price * 2 for c in CH}
pool = ThreadPoolExecutor(4)


def swap(c, zero_for_one, amount, limit):
    tx = router[c].functions.swap(KEY, (zero_for_one, -amount, limit), (False, False), b"").build_transaction(
        {"from": acct.address, "nonce": nonce[c], "gas": 400_000, "gasPrice": gas_price[c], "chainId": c})
    nonce[c] += 1
    return w3[c].eth.send_raw_transaction(acct.sign_transaction(tx).raw_transaction)


def slot0(c):
    for _ in range(5):
        try:
            return sv[c].functions.getSlot0(POOL_ID).call(block_identifier="latest")[0]
        except Exception:
            time.sleep(0.2)
    raise RuntimeError("slot0 failed")


def block_ms(c, n):
    for _ in range(20):  # a lagging node behind the load balancer can return null for a fresh block
        b = w3[c].provider.make_request("eth_getBlockByNumber", [hex(n), False]).get("result")
        if b: break
        time.sleep(0.3)
    return int(b["timestampMs"], 16) if "timestampMs" in b else int(b["timestamp"], 16) * 1000


def receipt(c, h):
    return w3[c].eth.wait_for_transaction_receipt(h, timeout=90, poll_latency=0.25)


def run(chain, zero_for_one):
    t_send = time.time()
    origin = swap(chain, zero_for_one, 20 * 10**18, MIN_LIMIT if zero_for_one else MAX_LIMIT)
    polls = 0
    while time.time() < t_send + 60:  # poll both pools until the gap shows at `latest`
        pa, pb = pool.map(slot0, (84532, 1301))
        polls += 1
        a_dear = pa * 10000 > pb * (10000 + MIN_GAP_SQRT_BPS)
        b_dear = pb * 10000 > pa * (10000 + MIN_GAP_SQRT_BPS)
        if a_dear or b_dear:
            break
    else:
        return {"error": "gap never seen"}
    t_detect = time.time()
    mid = (pa + pb) // 2
    legs = {84532: swap(84532, a_dear, MAX_IN, mid), 1301: swap(1301, not a_dear, MAX_IN, mid)}
    o = receipt(chain, origin)
    o_ms = block_ms(chain, o["blockNumber"])
    row = {"kind": "keeper", "gap_chain": NAME[chain], "zero_for_one": zero_for_one, "origin_tx": "0x" + origin.hex().removeprefix("0x"),
           "origin_block": o["blockNumber"], "polls": polls, "local_detect_ms": round((t_detect - t_send) * 1000), "legs": []}
    for c, h in legs.items():
        r = receipt(c, h)
        row["legs"].append({"chain": NAME[c], "tx": "0x" + h.hex().removeprefix("0x"), "block": r["blockNumber"],
                            "result": "filled" if r["status"] == 1 else "reverted", "ms_after_origin": block_ms(c, r["blockNumber"]) - o_ms})
    print(f"keeper gap on {NAME[chain]}: " + ", ".join(f"{l['chain']} {l['result']} +{l['ms_after_origin']} ms" for l in row["legs"])
          + f"  (gap seen after {row['local_detect_ms']} ms, {polls} polls)")
    return row


def main(n):
    rows = []
    for i in range(n):
        row = run(84532 if i % 2 == 0 else 1301, (i // 2) % 2 == 0)
        row["ts"] = int(time.time())
        rows.append(row)
        with open("results/baseline.jsonl", "a") as f:
            f.write(json.dumps(row) + "\n")
        time.sleep(3)
    ok = [max(l["ms_after_origin"] for l in r["legs"]) for r in rows if r.get("legs") and all(l["result"] == "filled" for l in r["legs"])]
    if ok:
        q = statistics.quantiles(ok, n=10) if len(ok) > 1 else [ok[0]] * 9
        print(f"keeper: {len(ok)}/{n} both filled; gap -> both legs filled p50 {statistics.median(ok):.0f} ms, p90 {q[8]:.0f} ms")


if __name__ == "__main__":
    main(int(sys.argv[1]))
