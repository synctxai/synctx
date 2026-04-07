// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BindingAttestation - Platform binding attestation verification contract
/// @notice Unified verification of Platform-issued (address, userId) binding signatures.
///         All Deal contracts requiring Twitter binding call this contract's verify(),
///         instead of implementing _verifyBinding() individually.
///
/// @dev Security model:
///   - platformSigner is the Platform EOA used to issue Binding Attestations
///   - Key rotation: owner calls setPlatformSigner() to update; all old signatures auto-invalidate
///   - Ownership: Ownable2Step, prevents accidental transfers
contract BindingAttestation {

    // ===================== State =====================

    address public owner;
    address public pendingOwner;
    address public platformSigner;

    // ===================== Events =====================

    event PlatformSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ===================== Errors =====================

    error ZeroAddress();
    error NotOwner();
    error NotPendingOwner();

    // ===================== Constructor =====================

    /// @param platformSigner_ Platform signing EOA address
    constructor(address platformSigner_) {
        if (platformSigner_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        platformSigner = platformSigner_;
        emit OwnershipTransferred(address(0), msg.sender);
        emit PlatformSignerUpdated(address(0), platformSigner_);
    }

    // ===================== Signature Verification =====================

    /// @notice Verify Platform's eth_sign signature for (address, userId) binding
    /// @param addr  The bound EVM address
    /// @param userId Twitter immutable user_id
    /// @param sig   Platform's signature of keccak256(abi.encodePacked(addr, userId)) (65 bytes)
    /// @return true if and only if the signature is valid and the signer == platformSigner
    function verify(address addr, uint64 userId, bytes calldata sig) external view returns (bool) {
        bytes32 hash = keccak256(abi.encodePacked(addr, userId));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        if (sig.length != 65) return false;

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return false;
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return false;

        address recovered = ecrecover(ethHash, v, r, s);
        return recovered == platformSigner;
    }

    // ===================== Admin Functions =====================

    /// @notice Update platformSigner (key rotation)
    /// @dev After update, all old signatures are auto-invalidated; users must re-obtain attestations
    function setPlatformSigner(address newSigner) external {
        _onlyOwner();
        if (newSigner == address(0)) revert ZeroAddress();
        address old = platformSigner;
        platformSigner = newSigner;
        emit PlatformSignerUpdated(old, newSigner);
    }

    // ===================== Ownable2Step =====================

    function transferOwnership(address newOwner) external {
        _onlyOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address old = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, msg.sender);
    }

    // ===================== Internal =====================

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }
}
