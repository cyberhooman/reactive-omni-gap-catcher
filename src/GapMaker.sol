// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolSwapTest} from "./V4.sol";
import {Token} from "./Token.sol";

/// The judge button: anyone can open a price gap on this chain's pool with one call.
contract GapMaker {
    IPoolSwapTest public immutable router;
    PoolKey public key;

    constructor(IPoolSwapTest router_, PoolKey memory key_) {
        router = router_;
        key = key_;
        Token(Currency.unwrap(key_.currency0)).approve(address(router_), type(uint256).max);
        Token(Currency.unwrap(key_.currency1)).approve(address(router_), type(uint256).max);
    }

    /// Mints `amountIn` of the input token and swaps all of it into the pool.
    function makeGap(bool zeroForOne, uint256 amountIn) external {
        PoolKey memory k = key;
        Token(Currency.unwrap(zeroForOne ? k.currency0 : k.currency1)).mint(address(this), amountIn);
        router.swap(
            k,
            SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            IPoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}
