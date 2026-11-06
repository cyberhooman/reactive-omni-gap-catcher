// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";

/// Destination contract with NO sender check: it records who delivered the callback
/// (msg.sender) and what the network injected as the first argument.
contract ProbeCallback is AbstractCallback {
    event Ponged(address proxy, address injected, uint256 indexed id, uint256 originChain, uint256 originBlock, uint256 destBlock, uint256 destTs);

    constructor(IPayable proxy) payable AbstractCallback(proxy, address(0)) {}

    function pong(address injected, uint256 id, uint256 originChain, uint256 originBlock) external {
        emit Ponged(msg.sender, injected, id, originChain, originBlock, block.number, block.timestamp);
    }

    function coverDebt() external {
        _coverDebt();
    }
}
