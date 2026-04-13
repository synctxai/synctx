// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ERC1967Proxy - Minimal UUPS-compatible proxy (OpenZeppelin-aligned)
/// @dev Stores implementation address at ERC-1967 slot. All calls delegated to implementation.
///      Upgrade logic lives in the implementation (UUPS pattern), not in the proxy.
contract ERC1967Proxy {

    /// @dev ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @param implementation_ Initial implementation address
    /// @param data Initializer calldata (delegatecall to implementation)
    constructor(address implementation_, bytes memory data) {
        if (implementation_.code.length == 0) revert("impl not contract");
        assembly { sstore(_IMPLEMENTATION_SLOT, implementation_) }
        if (data.length > 0) {
            (bool ok, ) = implementation_.delegatecall(data);
            require(ok, "init failed");
        }
    }

    fallback() external payable {
        assembly {
            let impl := sload(_IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    receive() external payable {}
}
