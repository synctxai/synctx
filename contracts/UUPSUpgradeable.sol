// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title UUPSUpgradeable - Minimal UUPS upgrade mechanism (OpenZeppelin-aligned)
/// @dev Implementation contracts inherit this to support upgrades via ERC-1967 proxy.
///      Subclass must override `_authorizeUpgrade` to restrict who can upgrade.
abstract contract UUPSUpgradeable {

    /// @dev ERC-1967 implementation slot
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    error NotProxy();
    error NewImplNotUUPS();

    event Upgraded(address indexed implementation);

    /// @dev Guard: must be called through a proxy (delegatecall), not directly.
    modifier onlyProxy() {
        if (address(this) == __self) revert NotProxy();
        _;
    }

    /// @dev The address of the original deployment (implementation contract itself).
    ///      Set in constructor; used by onlyProxy to detect direct calls.
    address private immutable __self = address(this);

    /// @notice UUPS magic value — proves this contract is a valid UUPS implementation.
    function proxiableUUID() external view virtual returns (bytes32) {
        if (address(this) != __self) {
            // Called through proxy — OK
        }
        return _IMPLEMENTATION_SLOT;
    }

    /// @notice Upgrade the implementation. Only callable through proxy.
    /// @param newImplementation New implementation address
    function upgradeToAndCall(address newImplementation, bytes memory data) external onlyProxy {
        _authorizeUpgrade(newImplementation);

        // Verify new implementation supports UUPS
        try UUPSUpgradeable(newImplementation).proxiableUUID() returns (bytes32 slot) {
            if (slot != _IMPLEMENTATION_SLOT) revert NewImplNotUUPS();
        } catch {
            revert NewImplNotUUPS();
        }

        assembly { sstore(_IMPLEMENTATION_SLOT, newImplementation) }
        emit Upgraded(newImplementation);

        if (data.length > 0) {
            (bool ok, ) = newImplementation.delegatecall(data);
            require(ok, "upgrade call failed");
        }
    }

    /// @dev Override to restrict upgrade access. Typically `require(msg.sender == owner)`.
    function _authorizeUpgrade(address newImplementation) internal virtual;
}
