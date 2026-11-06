// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GapCatcher} from "../src/GapCatcher.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// Stands in for Lasna's system contract at 0x8888: records callback requests.
contract MockSystem {
    ISystemContract.CallbackConfiguration_V_1_0[] public cbs;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        cbs.push(c);
    }

    function count() external view returns (uint256) {
        return cbs.length;
    }

    function payload(uint256 i) external view returns (bytes memory) {
        return cbs[i].payload;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract GapCatcherTest is Test {
    address constant SYS = 0x8888888888888888888888888888888888888888;
    uint256 constant A = 84532;
    uint256 constant B = 1301;
    address constant PM_A = address(0xA1);
    address constant PM_B = address(0xB1);
    address constant EX_A = address(0xA2);
    address constant EX_B = address(0xB2);
    uint256 constant POOL = 0x1234;
    uint256 constant SWAP = 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f;
    uint256 constant Q96 = 2 ** 96;
    MockSystem sys;
    GapCatcher gc;
    uint256 blk = 100;

    function setUp() public {
        vm.etch(SYS, address(new MockSystem()).code);
        sys = MockSystem(payable(SYS));
        vm.warp(1000);
        gc = new GapCatcher(A, PM_A, B, PM_B, POOL, 50, 1e18, 2e18);
        gc.setExecutors(EX_A, EX_B);
    }

    function _log(uint256 chainId, address src, uint256 t0, uint256 t1, bytes memory data)
        internal
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = chainId;
        l.contractAddress = src;
        l.topic0 = t0;
        l.topic1 = t1;
        l.data = data;
        l.blockNumber = ++blk;
        l.txHash = 0xabc;
    }

    function _swap(uint256 chainId, uint256 sqrtP) internal {
        address pm = chainId == A ? PM_A : PM_B;
        vm.prank(SYS);
        gc.react(_log(chainId, pm, SWAP, POOL, abi.encode(int128(0), int128(0), uint160(sqrtP), uint128(0), int24(0), uint24(3000))));
    }

    function _filled(uint256 chainId, uint256 id, bool zeroForOne, uint256 out) internal {
        vm.prank(SYS);
        gc.react(
            _log(chainId, chainId == A ? EX_A : EX_B, uint256(keccak256("Filled(uint256,bool,uint256,uint256,uint160,uint256,uint256)")), id, abi.encode(zeroForOne, uint256(1), out, uint160(Q96), A, blk))
        );
    }

    function _skipped(uint256 chainId, uint256 id) internal {
        vm.prank(SYS);
        gc.react(
            _log(chainId, chainId == A ? EX_A : EX_B, uint256(keccak256("Skipped(uint256,uint8,uint160,uint256,uint256)")), id, abi.encode(uint8(2), uint160(Q96), A, blk))
        );
    }

    function _leg(uint256 i) internal view returns (uint256 chainId, address to, bool zeroForOne, uint160 limit, uint256 maxIn) {
        (chainId, to,,) = sys.cbs(i);
        bytes memory p = sys.payload(i);
        bytes memory args = new bytes(p.length - 4);
        for (uint256 j = 0; j < args.length; j++) args[j] = p[j + 4];
        (,, zeroForOne, limit, maxIn,,,) = abi.decode(args, (address, uint256, bool, uint160, uint256, uint256, uint256, uint256));
    }

    function test_subFeeGapDoesNotFire() public {
        _swap(A, Q96);
        _swap(B, Q96 * 10040 / 10000); // 0.4% sqrt gap < 0.5% threshold
        assertEq(sys.count(), 0);
        assertEq(gc.inflight(), 0);
    }

    function test_gapFiresBothLegsFromOneReact() public {
        _swap(A, Q96);
        _swap(B, Q96 * 101 / 100); // B dear by 1% in sqrt price
        assertEq(sys.count(), 2);
        uint160 mid = uint160((Q96 + Q96 * 101 / 100) / 2);
        (uint256 c0, address t0, bool z0, uint160 l0, uint256 m0) = _leg(0);
        (uint256 c1, address t1, bool z1, uint160 l1, uint256 m1) = _leg(1);
        // A is cheap: buy token0 there (pay token1); B is dear: sell token0 there.
        assertEq(c0, A);
        assertEq(t0, EX_A);
        assertFalse(z0);
        assertEq(m0, 2e18);
        assertEq(c1, B);
        assertEq(t1, EX_B);
        assertTrue(z1);
        assertEq(m1, 1e18);
        assertEq(l0, mid);
        assertEq(l1, mid);
        assertEq(gc.inflight(), 1);
    }

    function test_lockBlocksUntilBothLegsReport() public {
        _swap(A, Q96);
        _swap(B, Q96 * 101 / 100);
        vm.warp(block.timestamp + 10);
        _swap(A, Q96 * 99 / 100); // still a gap, but in flight
        assertEq(sys.count(), 2);
        _filled(A, 1, false, 5);
        assertEq(gc.inflight(), 1);
        _filled(B, 1, true, 5);
        assertEq(gc.inflight(), 0);
        _swap(A, Q96 * 99 / 100); // gap still open and cooldown passed: fires again
        assertEq(sys.count(), 4);
        assertEq(gc.inflight(), 2);
    }

    function test_cooldownAndTimeout() public {
        _swap(A, Q96);
        _swap(B, Q96 * 101 / 100);
        _filled(A, 1, false, 5);
        _filled(B, 1, true, 5);
        _swap(A, Q96); // gap open but within the 5 s cooldown
        assertEq(sys.count(), 2);
        vm.warp(block.timestamp + 6);
        _swap(A, Q96);
        assertEq(sys.count(), 4); // id 2 in flight, never reported
        vm.warp(block.timestamp + 61);
        _swap(A, Q96);
        assertEq(sys.count(), 6); // lock timed out, id 3 fires
        assertEq(gc.inflight(), 3);
    }

    function test_oneLegFilledIsUnwound() public {
        _swap(A, Q96);
        _swap(B, Q96 * 101 / 100);
        _filled(B, 1, true, 777); // B sold token0, received 777 token1
        _skipped(A, 1);
        assertEq(sys.count(), 3);
        (uint256 c, address to, bool z, uint160 lim, uint256 m) = _leg(2);
        assertEq(c, B);
        assertEq(to, EX_B);
        assertFalse(z); // buy token0 back with the token1 received
        assertEq(m, 777);
        assertEq(lim, 1461446703485210103287273052203988822378723970341);
        assertTrue(gc.unwinding());
        _filled(B, 1, false, 700);
        assertEq(gc.inflight(), 0);
        assertFalse(gc.unwinding());
    }

    function test_bothSkippedReleases() public {
        _swap(A, Q96);
        _swap(B, Q96 * 101 / 100);
        _skipped(A, 1);
        _skipped(B, 1);
        assertEq(sys.count(), 2);
        assertEq(gc.inflight(), 0);
    }

    function test_ignoresStaleAndForeignLogs() public {
        _swap(A, Q96);
        blk -= 5; // an older Base log arriving late must not overwrite the price
        _swap(A, Q96 * 2);
        (,,, uint160 pA,) = gc.a();
        assertEq(pA, Q96);
        _swap(B, Q96 * 101 / 100);
        // a Filled from an address that is not our executor is ignored
        vm.prank(SYS);
        gc.react(_log(A, address(0xdead), uint256(keccak256("Filled(uint256,bool,uint256,uint256,uint160,uint256,uint256)")), 1, abi.encode(false, uint256(1), uint256(1), uint160(Q96), A, blk)));
        assertEq(gc.doneMask(), 0);
    }

    function test_onlySystemCanReact() public {
        IReactive.LogRecord memory l = _log(A, PM_A, SWAP, POOL, abi.encode(int128(0), int128(0), uint160(Q96), uint128(0), int24(0), uint24(3000)));
        vm.expectRevert();
        gc.react(l);
    }
}
