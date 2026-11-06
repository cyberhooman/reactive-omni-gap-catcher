// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolSwapTest} from "./V4.sol";
import {Token} from "./Token.sol";

/// One per chain. Holds inventory of both tokens and trades only when the GapCatcher on Lasna says so.
/// The trade is exact input with the price limit at the cross-chain midpoint, so the pool sizes the trade.
contract Executor is AbstractCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint8 public constant LATE = 1; // deadline passed
    uint8 public constant GONE = 2; // price already at or past the limit
    uint8 public constant FAILED = 3; // swap reverted

    IPoolManager public immutable manager;
    IPoolSwapTest public immutable router;
    PoolKey public key;

    event Filled(uint256 indexed id, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceAfter, uint256 originChain, uint256 originBlock);
    event Skipped(uint256 indexed id, uint8 reason, uint160 sqrtPrice, uint256 originChain, uint256 originBlock);

    constructor(IPayable proxy, address reactive, IPoolManager manager_, IPoolSwapTest router_, PoolKey memory key_)
        payable
        AbstractCallback(proxy, reactive)
    {
        manager = manager_;
        router = router_;
        key = key_;
        Token(Currency.unwrap(key_.currency0)).approve(address(router_), type(uint256).max);
        Token(Currency.unwrap(key_.currency1)).approve(address(router_), type(uint256).max);
    }

    /// Callback from the Reactive proxy. `rvm` is overwritten by the network with the sending reactive contract.
    function fill(
        address rvm,
        uint256 id,
        bool zeroForOne,
        uint160 limit,
        uint256 maxIn,
        uint256 deadline,
        uint256 originChain,
        uint256 originBlock
    ) external onlyServiceProvider onlyCallbackSender(rvm) {
        PoolKey memory k = key;
        (uint160 p,,,) = manager.getSlot0(k.toId());
        if (block.timestamp > deadline) {
            emit Skipped(id, LATE, p, originChain, originBlock);
            return;
        }
        if (zeroForOne ? p <= limit : p >= limit) {
            emit Skipped(id, GONE, p, originChain, originBlock);
            return;
        }
        uint256 bal = Token(Currency.unwrap(zeroForOne ? k.currency0 : k.currency1)).balanceOf(address(this));
        if (maxIn > bal) maxIn = bal;
        try router.swap(k, SwapParams(zeroForOne, -int256(maxIn), limit), IPoolSwapTest.TestSettings(false, false), "")
        returns (BalanceDelta d) {
            (int128 a0, int128 a1) = (d.amount0(), d.amount1());
            (uint160 pAfter,,,) = manager.getSlot0(k.toId());
            emit Filled(
                id,
                zeroForOne,
                uint128(zeroForOne ? -a0 : -a1),
                uint128(zeroForOne ? a1 : a0),
                pAfter,
                originChain,
                originBlock
            );
        } catch {
            emit Skipped(id, FAILED, p, originChain, originBlock);
        }
    }

    function coverDebt() external {
        _coverDebt();
    }
}
