// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// Lasna. Watches the twin pools on two chains. When their prices drift apart by more than the fees,
/// one react() sends two callbacks: sell token0 on the dear chain and buy it on the cheap chain.
/// Executor results come back as events; if exactly one leg fills, the filled leg is unwound.
contract GapCatcher is AbstractReactive {
    uint256 constant SWAP = 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f;
    uint256 constant FILLED = uint256(keccak256("Filled(uint256,bool,uint256,uint256,uint160,uint256,uint256)"));
    uint64 constant GAS = 1_000_000;
    uint256 public constant COOLDOWN = 5; // s between catches
    uint256 public constant LOCK_TIMEOUT = 60; // s before a lost leg stops blocking new catches
    uint256 public constant DEADLINE = 15; // s a callback stays valid on the destination chain
    uint160 constant MIN_LIMIT = 4295128740; // TickMath.MIN_SQRT_PRICE + 1
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970341; // MAX_SQRT_PRICE - 1

    uint8 public constant BOTH_FILLED = 1;
    uint8 public constant BOTH_SKIPPED = 2;
    uint8 public constant UNWOUND = 3;
    uint8 public constant TIMED_OUT = 4;

    struct Side {
        uint256 chainId;
        address manager; // v4 PoolManager
        address executor;
        uint160 sqrtP;
        uint256 lastBlock;
    }

    address public immutable owner;
    uint256 public immutable poolId;
    Side public a;
    Side public b;
    uint256 public minGapSqrtBps; // sqrt-price gap that fires; 50 ~ a 1% price gap
    uint256 public maxIn0; // per-leg size when selling token0
    uint256 public maxIn1; // per-leg size when buying token0

    uint256 public nextId = 1;
    uint256 public inflight; // 0 = idle
    uint256 public lockedAt;
    uint256 public lastFire;
    uint8 public doneMask; // bit 1 = side a reported, bit 2 = side b
    uint8 public filledMask;
    bool public unwinding;
    mapping(uint8 => bool) unwindDir; // per side: direction that reverses its fill
    mapping(uint8 => uint256) unwindAmt;

    event Requested(uint256 indexed id, uint256 originChain, uint256 originBlock, uint256 originTx, uint160 sqrtA, uint160 sqrtB, uint160 mid);
    event Unwinding(uint256 indexed id, uint256 chainId, uint256 amountIn);
    event Released(uint256 indexed id, uint8 outcome);

    constructor(
        uint256 chainA,
        address managerA,
        uint256 chainB,
        address managerB,
        uint256 poolId_,
        uint256 minGapSqrtBps_,
        uint256 maxIn0_,
        uint256 maxIn1_
    ) payable {
        owner = msg.sender;
        poolId = poolId_;
        a.chainId = chainA;
        a.manager = managerA;
        b.chainId = chainB;
        b.manager = managerB;
        minGapSqrtBps = minGapSqrtBps_;
        maxIn0 = maxIn0_;
        maxIn1 = maxIn1_;
        SYSTEM.subscribe(chainA, managerA, SWAP, poolId_, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainB, managerB, SWAP, poolId_, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// Executors are deployed after this contract (they need its address), so they are wired in here.
    function setExecutors(address exA, address exB) external {
        require(msg.sender == owner && a.executor == address(0));
        a.executor = exA;
        b.executor = exB;
        SYSTEM.subscribe(a.chainId, exA, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(b.chainId, exB, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setParams(uint256 minGapSqrtBps_, uint256 maxIn0_, uint256 maxIn1_) external {
        require(msg.sender == owner);
        minGapSqrtBps = minGapSqrtBps_;
        maxIn0 = maxIn0_;
        maxIn1 = maxIn1_;
    }

    /// Never reverts on a well-formed log: unknown sources are ignored.
    function react(LogRecord calldata log) external onlySystem {
        if (log.topic0 == SWAP) {
            Side storage s = log.chainId == a.chainId ? a : b;
            if (log.chainId != s.chainId || log.blockNumber < s.lastBlock) return;
            s.lastBlock = log.blockNumber;
            (,, uint160 sqrtP) = abi.decode(log.data, (int128, int128, uint160));
            s.sqrtP = sqrtP;
            _maybeFire(log);
            return;
        }
        if (inflight == 0 || log.topic1 != inflight) return;
        uint8 bit;
        if (log.chainId == a.chainId && log.contractAddress == a.executor) bit = 1;
        else if (log.chainId == b.chainId && log.contractAddress == b.executor) bit = 2;
        else return;

        if (unwinding) {
            _release(UNWOUND);
            return;
        }
        doneMask |= bit;
        if (log.topic0 == FILLED) {
            filledMask |= bit;
            (bool zeroForOne,, uint256 amountOut) = abi.decode(log.data, (bool, uint256, uint256));
            unwindDir[bit] = !zeroForOne;
            unwindAmt[bit] = amountOut;
        }
        if (doneMask != 3) return;
        if (filledMask == 3) {
            _release(BOTH_FILLED);
            return;
        }
        if (filledMask == 0) {
            _release(BOTH_SKIPPED);
            return;
        }
        // Exactly one leg filled: swap its output back, no price limit, so inventory returns to token-neutral.
        unwinding = true;
        Side storage f = filledMask == 1 ? a : b;
        uint8 fb = filledMask;
        emit Unwinding(inflight, f.chainId, unwindAmt[fb]);
        _fill(f, inflight, unwindDir[fb], unwindDir[fb] ? MIN_LIMIT : MAX_LIMIT, unwindAmt[fb], type(uint256).max, log);
    }

    function _maybeFire(LogRecord calldata log) internal {
        if (a.sqrtP == 0 || b.sqrtP == 0 || a.executor == address(0)) return;
        if (inflight != 0) {
            if (block.timestamp < lockedAt + LOCK_TIMEOUT) return;
            _release(TIMED_OUT);
        }
        if (block.timestamp < lastFire + COOLDOWN) return;
        bool aDear = uint256(a.sqrtP) * 10000 > uint256(b.sqrtP) * (10000 + minGapSqrtBps);
        bool bDear = uint256(b.sqrtP) * 10000 > uint256(a.sqrtP) * (10000 + minGapSqrtBps);
        if (!aDear && !bDear) return;

        uint160 mid = uint160((uint256(a.sqrtP) + b.sqrtP) / 2);
        uint256 id = nextId++;
        inflight = id;
        lockedAt = lastFire = block.timestamp;
        doneMask = filledMask = 0;
        // Dear side sells token0 (zeroForOne, pays token0); cheap side buys token0 (pays token1).
        uint256 deadline = block.timestamp + DEADLINE;
        _fill(a, id, aDear, mid, aDear ? maxIn0 : maxIn1, deadline, log);
        _fill(b, id, !aDear, mid, aDear ? maxIn1 : maxIn0, deadline, log);
        emit Requested(id, log.chainId, log.blockNumber, log.txHash, a.sqrtP, b.sqrtP, mid);
    }

    function _fill(Side storage s, uint256 id, bool zeroForOne, uint160 limit, uint256 maxIn, uint256 deadline, LogRecord calldata log)
        internal
    {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: s.chainId,
                recipient: s.executor,
                gasLimit: GAS,
                payload: abi.encodeWithSignature(
                    "fill(address,uint256,bool,uint160,uint256,uint256,uint256,uint256)",
                    address(0),
                    id,
                    zeroForOne,
                    limit,
                    maxIn,
                    deadline,
                    log.chainId,
                    log.blockNumber
                )
            })
        );
    }

    function _release(uint8 outcome) internal {
        emit Released(inflight, outcome);
        inflight = 0;
        unwinding = false;
    }

    function coverDebt() external {
        _coverDebt();
    }
}
