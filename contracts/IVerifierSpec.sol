// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVerifierSpec - Business specification contract interface
/// @notice Defines the verification spec metadata and check logic.
/// @dev Each VerifierSpec defines: name/version/description + check() for EIP-712 signature verification.
///      check() reads DOMAIN_SEPARATOR and owner from the verifier instance via callback.
interface IVerifierSpec {

    /// @notice Spec name (e.g. "XQuoteVerifierSpec")
    function name() external pure returns (string memory);

    /// @notice Spec version (e.g. "1.0")
    function version() external pure returns (string memory);

    /// @notice Spec description — must document specParams abi.encode format: parameter names, types, order
    function description() external pure returns (string memory);

    /// @notice Verify EIP-712 signature validity
    /// @dev Each VerifierSpec defines its own check() with spec-specific business parameters.
    ///      The base interface does not declare check() because parameter signatures vary per spec.
    ///      Example: XQuoteVerifierSpec.check(verifierInstance, tweet_id, quoter_username, fee, deadline, sig)
    ///      Example: XFollowerQualityVerifierSpec.check(verifierInstance, username, fee, deadline, sig)
}
