// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierBase.sol";

/// @title XQuoteVerifier - X (Twitter) quote tweet verifier
/// @notice Verifier instance for X quote tweet verification.
/// @dev check() lives in XQuoteVerifierSpec, not here.
///      This contract inherits VerifierBase (owner, DOMAIN_SEPARATOR, reportResult, withdrawFees)
///      and points to XQuoteVerifierSpec via spec().
///
///      Responsibilities:
///      - XQuoteVerifierSpec: defines EIP-712 TYPEHASH, verifies signature validity
///      - XQuoteVerifier (this contract): holds owner, DOMAIN_SEPARATOR, submits verification results, manages fees
///      - Off-chain service: listens for VerificationRequested events, calls X API for actual verification, calls reportResult
contract XQuoteVerifier is VerifierBase {

    // ============ Constants ============

    /// @notice Off-chain service validates deadline ≤ now + MAX_SIGN_DEADLINE_SECONDS during signing
    /// @dev Not additionally checked on-chain — createDeal's signature verification implicitly ensures the deadline is within range.
    ///      This constant provides a standard parameter for off-chain services.
    uint256 public constant MAX_SIGN_DEADLINE_SECONDS = 3600;

    // ============ Immutables ============

    /// @notice XQuoteVerifierSpec contract address
    address public immutable SPEC;

    // ============ Constructor ============

    /// @param specAddress The deployed XQuoteVerifierSpec contract address
    constructor(address specAddress) VerifierBase("XQuoteVerifier", "1") {
        require(specAddress != address(0), "spec cannot be zero");
        SPEC = specAddress;
    }

    // ============ IVerifier Implementation ============

    /// @inheritdoc IVerifier
    function description() external pure override(VerifierBase) returns (string memory) {
        return
            "Verify quote-tweets on X (Twitter). Checks if a specific user_id quoted a given tweet. "
            "EIP-712 signed, max sign deadline 1 hour (3600s).";
    }

    /// @inheritdoc IVerifier
    function spec() external view override(VerifierBase) returns (address) {
        return SPEC;
    }
}
