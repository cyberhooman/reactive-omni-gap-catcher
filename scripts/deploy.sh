#!/usr/bin/env bash
# One-shot deploy of the gap catcher: tokens + pools on Base Sepolia and Unichain Sepolia,
# GapCatcher on Lasna, an Executor and a GapMaker per chain. Writes deployments.json.
# Needs DEPLOYER_PRIVATE_KEY (testnet only). Run from the repo root: bash scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
PK=$DEPLOYER_PRIVATE_KEY
ME=$(cast wallet address --private-key "$PK")

BASE=https://sepolia.base.org;  BASE_ID=84532
UNI=https://sepolia.unichain.org; UNI_ID=1301
LASNA=https://lasna-rpc.rnk.dev/
FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C   # deterministic CREATE2 deployer, on both L2s
declare -A PM=([$BASE]=0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 [$UNI]=0x00b036b58a818b1bc34d502d3fe730db729e62ac)
declare -A ROUTER=([$BASE]=0x8B5bcC363ddE2614281aD875bad385E0A785D3B9 [$UNI]=0x9140a78c1a137c7ff1c151ec8231272af78a99a4)
declare -A LIQ=([$BASE]=0x37429cD17Cb1454C34E7F50b09725202Fd533039 [$UNI]=0x5fa728c0a5cfd51bee4b060773f50554c0c8a7ab)
declare -A STATEVIEW=([$BASE]=0x571291b572ed32ce6751a2cb2486ebee8defb9b4 [$UNI]=0xc199f1072a74d4e905aba1a84d9a45e2546b6222)
declare -A PROXY=([$BASE]=0x476F44b11F5C942c58f4c8E3d0300E5710743585 [$UNI]=0x775c9B990ADe401060B78D0e98684eEf8d2466C1)
Q96=79228162514264337593543950336
SALT=$(cast keccak reactive-omni-gap-catcher-v1)
MIN_GAP_SQRT_BPS=${MIN_GAP_SQRT_BPS:-50}   # ~1% price gap; fees are 0.3% a leg
MAX_IN=${MAX_IN:-50000000000000000000}     # 50 tokens per leg, the price limit sizes the real trade

forge build -q
# Load-balanced RPCs (Unichain) can hand out a stale nonce, so every write retries.
send() {
  local out
  for _ in 1 2 3 4; do
    out=$(cast send --rpc-url "$1" --private-key "$PK" "${@:2}" --json 2>/dev/null) && break
    sleep 3
  done
  echo "$out" | python -c "import json,sys;d=json.load(sys.stdin);assert d['status']=='0x1',d;print(d['transactionHash'])"
}
create() {
  local a
  for _ in 1 2 3 4; do
    a=$(forge create --broadcast --rpc-url "$1" --private-key "$PK" "${@:2}" 2>/dev/null | awk '/Deployed to:/{print $3}')
    [ -n "$a" ] && break
    sleep 3
  done
  [ -n "$a" ] || { echo "create failed: ${*:2}" >&2; exit 1; }
  echo "$a"
}

# 1. Tokens: same CREATE2 salt + init code on both chains -> same addresses -> same PoolKey and PoolId.
TOKEN_CODE=$(forge inspect src/Token.sol:Token bytecode)
tok() { echo "$TOKEN_CODE$(cast abi-encode 'constructor(string,string)' "$1" "$2" | cut -c3-)"; }
INIT_A=$(tok "Gap Alpha" GAPA); INIT_B=$(tok "Gap Beta" GAPB)
c2() { local d; d=$(cast keccak "0xff${FACTORY:2}${SALT:2}$(cast keccak "$1" | cut -c3-)"); cast to-check-sum-address "0x${d:26}"; }
TA=$(c2 "$INIT_A"); TB=$(c2 "$INIT_B")
for R in $BASE $UNI; do
  [ "$(cast code $TA --rpc-url $R)" != "0x" ] || send $R $FACTORY "$SALT${INIT_A:2}" > /dev/null
  [ "$(cast code $TB --rpc-url $R)" != "0x" ] || send $R $FACTORY "$SALT${INIT_B:2}" > /dev/null
  [ "$(cast code $TA --rpc-url $R)" != "0x" ] && [ "$(cast code $TB --rpc-url $R)" != "0x" ] || { echo "token deploy failed on $R"; exit 1; }
done
if [ "$(python -c "print(int('$TA',16) < int('$TB',16))")" = True ]; then T0=$TA; T1=$TB; else T0=$TB; T1=$TA; fi
KEY="($T0,$T1,3000,60,0x0000000000000000000000000000000000000000)"
POOL_ID=$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' $T0 $T1 3000 60 0x0000000000000000000000000000000000000000)")
echo "token0 $T0  token1 $T1  poolId $POOL_ID"

# 2. One full-range pool per chain at price 1.
for R in $BASE $UNI; do
  [ "$(cast call ${STATEVIEW[$R]} 'getLiquidity(bytes32)(uint128)' $POOL_ID --rpc-url $R)" = 0 ] || { echo "pool on $R already has liquidity"; continue; }
  send $R ${PM[$R]} "initialize((address,address,uint24,int24,address),uint160)" "$KEY" $Q96 > /dev/null || echo "pool already initialised on $R"
  for T in $T0 $T1; do send $R $T "mint(address,uint256)" $ME 1000000000000000000000000 > /dev/null; send $R $T "approve(address,uint256)" ${LIQ[$R]} $(cast max-uint) > /dev/null; done
  send $R ${LIQ[$R]} "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" "$KEY" "(-887220,887220,1000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000)" 0x > /dev/null
done

# 3. GapCatcher on Lasna, funded for reactive transactions.
GC=$(create $LASNA src/GapCatcher.sol:GapCatcher --value 1ether --constructor-args $BASE_ID ${PM[$BASE]} $UNI_ID ${PM[$UNI]} $POOL_ID $MIN_GAP_SQRT_BPS $MAX_IN $MAX_IN)
echo "GapCatcher $GC"

# 4. Executor (funded for callbacks, stocked with inventory) and GapMaker per chain.
declare -A EX GM
for R in $BASE $UNI; do
  EX[$R]=$(create $R src/Executor.sol:Executor --value 0.002ether --constructor-args ${PROXY[$R]} $GC ${PM[$R]} ${ROUTER[$R]} "$KEY")
  for T in $T0 $T1; do send $R $T "mint(address,uint256)" ${EX[$R]} 1000000000000000000000 > /dev/null; done
  GM[$R]=$(create $R src/GapMaker.sol:GapMaker --constructor-args ${ROUTER[$R]} "$KEY")
  echo "$R executor ${EX[$R]} gapmaker ${GM[$R]}"
done
send $LASNA $GC "setExecutors(address,address)" ${EX[$BASE]} ${EX[$UNI]} > /dev/null

cat > deployments.json <<EOF
{
  "token0": "$T0", "token1": "$T1", "poolId": "$POOL_ID",
  "lasna": {"chainId": 5318007, "gapCatcher": "$GC"},
  "base": {"chainId": $BASE_ID, "executor": "${EX[$BASE]}", "gapMaker": "${GM[$BASE]}", "poolManager": "${PM[$BASE]}"},
  "unichain": {"chainId": $UNI_ID, "executor": "${EX[$UNI]}", "gapMaker": "${GM[$UNI]}", "poolManager": "${PM[$UNI]}"}
}
EOF
echo "wrote deployments.json"
