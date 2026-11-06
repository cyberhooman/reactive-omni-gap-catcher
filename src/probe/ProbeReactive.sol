// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// Lasna side of the probe: every Pinged on chain A or B triggers a pong callback on the same chain.
contract ProbeReactive is AbstractReactive {
    uint256 constant PINGED = uint256(keccak256("Pinged(uint256,uint256)"));
    mapping(uint256 => address) public dest; // chainId => ProbeCallback

    constructor(uint256 chainA, address pingA, address destA, uint256 chainB, address pingB, address destB) payable {
        dest[chainA] = destA;
        dest[chainB] = destB;
        SYSTEM.subscribe(chainA, pingA, PINGED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainB, pingB, PINGED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function react(LogRecord calldata log) external onlySystem {
        bytes memory payload = abi.encodeWithSignature(
            "pong(address,uint256,uint256,uint256)", address(0), log.topic1, log.chainId, log.blockNumber
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({chainId: log.chainId, recipient: dest[log.chainId], gasLimit: 200000, payload: payload})
        );
    }

    function coverDebt() external {
        _coverDebt();
    }
}
