// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVerifier.sol";

/// @title VerifierSpec - Business verification specification base contract
/// @notice All VerifierSpec contracts must inherit this abstract contract.
/// @dev Provides metadata interface (name/version/description) and shared EIP-712 signature recovery logic.
///      Subcontracts only need to define TYPEHASH, check() parameters, and metadata overrides.
///      Spec is only responsible for signature format verification (recovering signer address), not signer authorization.
///
///      Inheritance example:
///        abstract contract VerifierSpec
///          └── XQuoteVerifierSpec  (defines TYPEHASH + check + metadata)
abstract contract VerifierSpec {

    // ============ Errors ============

    error SignatureExpired();        // Signature has expired
    error InvalidSignatureLength();  // Signature length invalid (must be 65 bytes)
    error InvalidSignatureV();       // Signature v value invalid
    error InvalidSignature();        // ecrecover returned zero address
    error SignatureMalleability();  // Signature s value too high (EIP-2 anti-malleability)

    // ============ Metadata (subcontracts must override) ============

    /// @notice Spec name (e.g. "X Quote Tweet Verifier Spec")
    function name() external pure virtual returns (string memory);

    /// @notice Spec version (e.g. "1.0")
    function version() external pure virtual returns (string memory);

    /// @notice Spec description — must document specParams abi.encode format: parameter names, types, order.
    ///         Must declare result type:
    ///         - Boolean: result uses only 1 (yes) / -1 (no)
    ///         - Score: result in [1, maxScore] range, must declare maxScore (≤ 127)
    function description() external pure virtual returns (string memory);

    // ============ Shared EIP-712 Logic ============

    /// @dev Recover EIP-712 signer address (no authorization check; caller compares the returned address)
    /// @param verifierInstance Verifier contract address (reads DOMAIN_SEPARATOR)
    /// @param structHash The structHash constructed by the subcontract using TYPEHASH + business parameters
    /// @param deadline Signature expiration timestamp (Unix seconds)
    /// @param sig EIP-712 signature (65 bytes)
    /// @return Signer address
    function _recoverEIP712Signer(
        address verifierInstance,
        bytes32 structHash,
        uint256 deadline,
        bytes calldata sig
    ) internal view returns (address) {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 domainSeparator = IVerifier(verifierInstance).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return _recoverSigner(digest, sig);
    }

    /// @dev Recover signer address from EIP-712 digest.
    ///      Enforces low-s value (EIP-2) to prevent signature malleability.
    ///      Signature malleability: the same message can have two valid signatures (s and n-s);
    ///      the low-s constraint ensures only one valid signature, preventing third parties from "flipping" signatures.
    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;

        // Extract r, s, v from calldata (more gas-efficient than abi.decode)
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        // Normalize v (compatible with v=0/1 from some wallets and v=27/28 standard)
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignatureV();

        // Reject high s-values to prevent signature malleability (EIP-2)
        // Half of secp256k1 curve order = 0x7FFFFFFF...681B20A0
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert SignatureMalleability();
        }

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }
}
