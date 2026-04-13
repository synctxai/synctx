// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierBase.sol";

/// @title XFollowVerifier - X (Twitter) follow relationship verifier
/// @notice Verifier instance for X follow relationship verification.
/// @dev check() lives in XFollowVerifierSpec, not here.
///      This contract inherits VerifierBase (owner, DOMAIN_SEPARATOR, reportResult, withdrawFees)
///      and points to XFollowVerifierSpec via spec().
///
///      Responsibilities:
///      - XFollowVerifierSpec: defines EIP-712 TYPEHASH, verifies signature validity
///      - XFollowVerifier (this contract): holds owner, DOMAIN_SEPARATOR, submits verification results, manages fees
///      - Off-chain service: listens for VerificationRequested events, queries external data sources, and reports result
contract XFollowVerifier is VerifierBase {

    // ============ Constants ============

    /// @notice Recommended off-chain signer policy: deadline <= now + MAX_SIGN_DEADLINE_SECONDS. NOT enforced on-chain.
    uint256 public constant MAX_SIGN_DEADLINE_SECONDS = 30 days;

    // ============ Immutables ============

    /// @notice XFollowVerifierSpec contract address
    address public immutable SPEC;

    // ============ Constructor ============

    /// @param specAddress The deployed XFollowVerifierSpec contract address
    constructor(address specAddress) VerifierBase("XFollowVerifier", "1") {
        require(specAddress != address(0), "spec cannot be zero");
        SPEC = specAddress;
    }

    // ============ IVerifier Implementation ============

    /// @inheritdoc IVerifier
    function description() external pure override(VerifierBase) returns (string memory) {
        return
            "Verifies whether a given address's bound X(Twitter) account is following target_user_id. "
            "EIP-712 signed. Verifier signatures expire within 30 days (2592000s) of issuance.";
    }

    /// @inheritdoc IVerifier
    function spec() external view override(VerifierBase) returns (address) {
        return SPEC;
    }
}
