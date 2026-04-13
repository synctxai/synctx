// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UUPSUpgradeable.sol";

/// @title TwitterVerification - Privacy-preserving Twitter binding contract
/// @notice Stores address → commitment (hash) mappings on-chain. Only deployed on OP chain.
///         Commitment = keccak256(userId, salt). Salt is stored off-chain in Platform DB.
///         userId is never exposed on-chain or in calldata.
///
/// @dev UUPS proxy pattern. All write operations restricted to `platform` EOA.
///      Ownership uses Ownable2Step. Owner controls upgrades and platform address.
///      Platform controls binding operations.
contract TwitterVerification is UUPSUpgradeable {

    // ===================== State (proxy-safe: no constructor init) =====================

    /// @dev Initialisation guard
    bool private _initialized;

    /// @notice Contract owner — can upgrade and set platform address
    address public owner;

    /// @notice Pending owner for Ownable2Step
    address public pendingOwner;

    /// @notice Platform EOA — the only address that can write bindings
    address public platform;

    /// @notice address → keccak256(userId, salt) commitment
    mapping(address => bytes32) public commitments;

    // ===================== Events =====================

    event Initialized(address indexed owner, address indexed platform);
    event PlatformUpdated(address indexed oldPlatform, address indexed newPlatform);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Bound(address indexed user, bytes32 commitment);
    event Rebound(address indexed user, bytes32 oldCommitment, bytes32 newCommitment);
    event Transferred(address indexed oldUser, address indexed newUser, bytes32 commitment);
    event Revoked(address indexed user);

    // ===================== Errors =====================

    error AlreadyInitialized();
    error ZeroAddress();
    error NotOwner();
    error NotPendingOwner();
    error NotPlatform();
    error AlreadyBound();
    error NotBound();

    // ===================== Modifiers =====================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPlatform() {
        if (msg.sender != platform) revert NotPlatform();
        _;
    }

    // ===================== Initializer (replaces constructor for proxy) =====================

    /// @notice Initialize the contract (called once via proxy constructor)
    /// @param owner_ Contract owner
    /// @param platform_ Platform EOA for binding operations
    function initialize(address owner_, address platform_) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || platform_ == address(0)) revert ZeroAddress();
        _initialized = true;
        owner = owner_;
        platform = platform_;
        emit Initialized(owner_, platform_);
    }

    // ===================== Binding Operations (platform only) =====================

    /// @notice Bind an address to a commitment
    /// @param user The EVM address to bind
    /// @param commitment keccak256(userId, salt) — computed off-chain by platform
    function bind(address user, bytes32 commitment) external onlyPlatform {
        if (user == address(0)) revert ZeroAddress();
        if (commitment == bytes32(0)) revert ZeroAddress();
        if (commitments[user] != bytes32(0)) revert AlreadyBound();
        commitments[user] = commitment;
        emit Bound(user, commitment);
    }

    /// @notice Rebind — user changed Twitter account
    /// @param user The EVM address
    /// @param newCommitment New commitment hash
    function rebind(address user, bytes32 newCommitment) external onlyPlatform {
        if (user == address(0)) revert ZeroAddress();
        if (newCommitment == bytes32(0)) revert ZeroAddress();
        bytes32 old = commitments[user];
        if (old == bytes32(0)) revert NotBound();
        commitments[user] = newCommitment;
        emit Rebound(user, old, newCommitment);
    }

    /// @notice Transfer binding to a new wallet
    /// @param oldUser Current bound address
    /// @param newUser New address to transfer binding to
    function transfer(address oldUser, address newUser) external onlyPlatform {
        if (oldUser == address(0) || newUser == address(0)) revert ZeroAddress();
        bytes32 c = commitments[oldUser];
        if (c == bytes32(0)) revert NotBound();
        if (commitments[newUser] != bytes32(0)) revert AlreadyBound();
        delete commitments[oldUser];
        commitments[newUser] = c;
        emit Transferred(oldUser, newUser, c);
    }

    /// @notice Revoke binding
    /// @param user The address to unbind
    function revoke(address user) external onlyPlatform {
        if (user == address(0)) revert ZeroAddress();
        if (commitments[user] == bytes32(0)) revert NotBound();
        delete commitments[user];
        emit Revoked(user);
    }

    // ===================== Read =====================

    /// @notice Check if an address has an active Twitter binding
    /// @param user The address to check
    /// @return true if the address has a non-zero commitment
    function isBound(address user) external view returns (bool) {
        return commitments[user] != bytes32(0);
    }

    // ===================== Admin =====================

    /// @notice Update the platform EOA address
    function setPlatform(address newPlatform) external onlyOwner {
        if (newPlatform == address(0)) revert ZeroAddress();
        address old = platform;
        platform = newPlatform;
        emit PlatformUpdated(old, newPlatform);
    }

    // ===================== Ownable2Step =====================

    function transferOwnership(address newOwner) external onlyOwner {
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

    // ===================== UUPS =====================

    /// @dev Only owner can authorize upgrades
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
