// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierBase.sol";

/// @title XRepostVerifier - X(Twitter) repost verifier
/// @notice Verifier instance for X(Twitter) repost verification (native repost(retweet) OR quote tweet).
/// @dev check() lives in XRepostVerifierSpec, not here.
///      This contract inherits VerifierBase (owner, DOMAIN_SEPARATOR, reportResult, withdrawFees)
///      and points to XRepostVerifierSpec via spec().
///
///      Responsibilities:
///      - XRepostVerifierSpec: defines EIP-712 TYPEHASH, verifies signature validity
///      - XRepostVerifier (this contract): holds owner, DOMAIN_SEPARATOR, submits verification results, manages fees
///      - Off-chain service: listens for VerificationRequested events, checks Twitter via
///        O(1) retweet-check + advanced_search, calls reportResult
///
///      Domain name "XRepostVerifier" MUST match the off-chain signer's EIP-712 domain.name.
contract XRepostVerifier is VerifierBase {

    // ============ Constants ============

    /// @notice Recommended off-chain signer policy: deadline ≤ now + MAX_SIGN_DEADLINE_SECONDS.
    /// @dev NOT enforced on-chain. Off-chain signers should reject requests exceeding this window.
    uint256 public constant MAX_SIGN_DEADLINE_SECONDS = 3600;

    // ============ Immutables ============

    /// @notice XRepostVerifierSpec contract address
    address public immutable SPEC;

    // ============ Constructor ============

    /// @param specAddress The deployed XRepostVerifierSpec contract address
    constructor(address specAddress) VerifierBase("XRepostVerifier", "1") {
        require(specAddress != address(0), "spec cannot be zero");
        SPEC = specAddress;
    }

    // ============ IVerifier Implementation ============

    /// @inheritdoc IVerifier
    function description() external pure override(VerifierBase) returns (string memory) {
        return
            "Verify reposts on X(Twitter). "
            "Matches native repost(retweet) OR quote tweet by the reposter's bound X(Twitter) account. "
            "EIP-712 signed. Verifier signatures expire within 1 hour (3600s) of issuance.";
    }

    /// @inheritdoc IVerifier
    function spec() external view override(VerifierBase) returns (address) {
        return SPEC;
    }
}
