// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Clones - EIP-1167 最小代理部署
/// @dev 轻量实现，与 OpenZeppelin Clones 等价。
library Clones {
    error CloneDeployFailed();

    /// @notice 部署 implementation 的 EIP-1167 最小代理
    /// @param implementation 实现合约地址
    /// @return instance 新部署的代理地址
    function clone(address implementation) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(96, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneDeployFailed();
    }
}
