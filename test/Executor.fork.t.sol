// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Executor} from "../src/Executor.sol";
import {GapMaker} from "../src/GapMaker.sol";
import {IPoolSwapTest, IPoolModifyLiquidityTest} from "../src/V4.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// Against the real Uniswap v4 contracts on a Base Sepolia fork.
contract ExecutorForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    IPoolSwapTest constant SWAP = IPoolSwapTest(0x8B5bcC363ddE2614281aD875bad385E0A785D3B9);
    IPoolModifyLiquidityTest constant LIQ = IPoolModifyLiquidityTest(0x37429cD17Cb1454C34E7F50b09725202Fd533039);
    address constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address constant RC = address(0x5eac7);
    uint160 constant Q96 = uint160(2 ** 96);

    PoolKey key;
    Executor ex;
    GapMaker gm;

    function setUp() public {
        vm.createSelectFork("https://sepolia.base.org");
        Token t0 = new Token("Gap A", "GAPA");
        Token t1 = new Token("Gap B", "GAPB");
        if (address(t0) > address(t1)) (t0, t1) = (t1, t0);
        key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(address(0)));
        PM.initialize(key, Q96);
        t0.mint(address(this), 1e24);
        t1.mint(address(this), 1e24);
        t0.approve(address(LIQ), type(uint256).max);
        t1.approve(address(LIQ), type(uint256).max);
        LIQ.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 1000e18, 0), "");
        ex = new Executor(IPayable(payable(PROXY)), RC, PM, SWAP, key);
        t0.mint(address(ex), 100e18);
        t1.mint(address(ex), 100e18);
        gm = new GapMaker(SWAP, key);
    }

    function _price() internal view returns (uint160 p) {
        (p,,,) = PM.getSlot0(key.toId());
    }

    function _fill(bool zeroForOne, uint160 limit, uint256 deadline) internal {
        vm.prank(PROXY);
        ex.fill(RC, 7, zeroForOne, limit, 50e18, deadline, 84532, 123);
    }

    function test_gapThenFillStopsAtTheLimit() public {
        gm.makeGap(true, 20e18); // sell token0: price falls ~4%, sqrt price ~2%
        uint160 low = _price();
        assertLt(low, Q96 * 99 / 100);
        uint160 mid = (low + Q96) / 2;
        vm.recordLogs();
        _fill(false, mid, block.timestamp + 15); // buy token0 back up to the midpoint
        assertEq(_price(), mid); // exact input, but the price limit sized the trade
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[logs.length - 1].topics[0], Executor.Filled.selector);
        (, uint256 amountIn, uint256 amountOut,,,) = abi.decode(logs[logs.length - 1].data, (bool, uint256, uint256, uint160, uint256, uint256));
        assertGt(amountIn, 0);
        assertLt(amountIn, 50e18);
        assertGt(amountOut, 0);
    }

    function test_skipsWhenPriceAlreadyPastLimit() public {
        gm.makeGap(true, 20e18);
        uint160 low = _price();
        vm.expectEmit(true, false, false, true, address(ex));
        emit Executor.Skipped(7, 2, low, 84532, 123);
        _fill(true, low + 1, block.timestamp + 15); // selling further down: limit is above the price
    }

    function test_skipsWhenLate() public {
        vm.expectEmit(true, false, false, false, address(ex));
        emit Executor.Skipped(7, 1, 0, 0, 0);
        _fill(true, Q96 / 2, block.timestamp - 1);
    }

    function test_rejectsWrongSenderOrCaller() public {
        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xbad), RC));
        ex.fill(address(0xbad), 7, true, Q96 / 2, 1e18, block.timestamp + 15, 84532, 123);
        vm.expectRevert();
        ex.fill(RC, 7, true, Q96 / 2, 1e18, block.timestamp + 15, 84532, 123); // not from the proxy
    }
}
