// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MetaTxMixin - Embedded meta-transaction support
/// @dev Each contract verifies signatures and tracks nonces itself; no external forwarder dependency.
///      Contracts inheriting this mixin provide gasless entry points via BySig functions.
///      Constructor path passes (name, version); clone path calls _initMetaTxDomain() in initialize().
abstract contract MetaTxMixin {

    // ===================== Errors =====================

    error MetaTxInvalidSignature();
    error MetaTxExpired();
    error MetaTxNonceMismatch();
    error MetaTxUnauthorizedRelayer();
    error PermitFailed();

    // ===================== Types =====================

    /// @dev Meta-transaction signature proof
    struct MetaTxProof {
        address signer;      // Actual user address
        address relayer;     // Authorized submitter (address(0) = anyone can submit)
        uint256 nonce;       // Signer's current nonce in this contract
        uint256 deadline;    // Signature validity (Unix seconds)
        bytes   signature;   // 65-byte ECDSA signature
    }

    /// @dev EIP-2612 Permit parameters (spender is fixed to address(this))
    struct PermitData {
        address token;       // ERC20 token address (address(0) = no permit needed)
        uint256 value;       // Approval amount
        uint256 deadline;    // Permit validity
        uint8   v;
        bytes32 r;
        bytes32 s;
    }

    // ===================== EIP-712 =====================

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,"
        "uint256 chainId,address verifyingContract)"
    );

    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;
    bytes32 private _hashedName;
    bytes32 private _hashedVersion;

    // ===================== Nonce =====================

    mapping(address => uint256) public nonces;

    // ===================== Initialization =====================

    /// @dev Constructor path: regular contracts pass name/version directly
    constructor(string memory name_, string memory version_) {
        _initMetaTxDomain(name_, version_);
    }

    /// @dev Clone path: called in initialize()
    ///      Can also be called by the constructor (constructor passes params then calls automatically)
    function _initMetaTxDomain(string memory name_, string memory version_) internal {
        _hashedName = keccak256(bytes(name_));
        _hashedVersion = keccak256(bytes(version_));
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    // ===================== Domain Separator =====================

    /// @notice Current chain's EIP-712 domain separator (auto-recomputed on chain fork)
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _cachedChainId && _cachedDomainSeparator != bytes32(0)) {
            return _cachedDomainSeparator;
        }
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            _DOMAIN_TYPEHASH, _hashedName, _hashedVersion,
            block.chainid, address(this)
        ));
    }

    // ===================== Core Verification =====================

    /// @dev Verify EIP-712 signature and consume nonce.
    ///      Nonce is incremented before return (CEI pattern); subsequent external calls cannot re-enter.
    /// @param structHash keccak256 hash of the business typed struct
    /// @param proof User's meta-tx signature proof
    function _verifyMetaTx(bytes32 structHash, MetaTxProof calldata proof) internal {
        // 1. Relayer binding (address(0) = anyone can submit)
        if (proof.relayer != address(0) && msg.sender != proof.relayer)
            revert MetaTxUnauthorizedRelayer();

        // 2. Deadline
        if (block.timestamp > proof.deadline) revert MetaTxExpired();

        // 3. Nonce (CEI: consumed before signature verification and any external call)
        if (nonces[proof.signer] != proof.nonce) revert MetaTxNonceMismatch();
        nonces[proof.signer] = proof.nonce + 1;

        // 4. Signature verification
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", DOMAIN_SEPARATOR(), structHash
        ));
        address recovered = _recoverSigner(digest, proof.signature);
        if (recovered != proof.signer || recovered == address(0))
            revert MetaTxInvalidSignature();
    }

    // ===================== Permit Helper =====================

    /// @dev Execute EIP-2612 permit, tolerating front-running (Uniswap V3 standard practice).
    ///      Skipped when permit.token == address(0). Spender is fixed to address(this).
    function _executePermit(PermitData calldata permit, address owner) internal {
        if (permit.token == address(0)) return;
        try IERC20Permit(permit.token).permit(
            owner, address(this), permit.value, permit.deadline,
            permit.v, permit.r, permit.s
        ) {} catch {
            if (IERC20Permit(permit.token).allowance(owner, address(this)) < permit.value) {
                revert PermitFailed();
            }
        }
    }

    // ===================== Signature Utilities =====================

    function _recoverSigner(bytes32 digest, bytes calldata sig)
        private pure returns (address)
    {
        if (sig.length != 65) revert MetaTxInvalidSignature();

        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(bytes1(sig[64:65]));

        // Normalize v (compatible with 0/1 and 27/28 formats)
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert MetaTxInvalidSignature();

        // EIP-2: reject malleable signatures (high-s)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0)
            revert MetaTxInvalidSignature();

        return ecrecover(digest, v, r, s);
    }
}

/// @dev Minimal EIP-2612 Permit interface
interface IERC20Permit {
    function permit(address owner, address spender, uint256 value,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function allowance(address owner, address spender) external view returns (uint256);
}
