// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// Origin-chain event source for the day-1 probe.
contract Ping {
    event Pinged(uint256 indexed id, uint256 ts);
    uint256 public n;

    function ping() external {
        emit Pinged(++n, block.timestamp);
    }
}
