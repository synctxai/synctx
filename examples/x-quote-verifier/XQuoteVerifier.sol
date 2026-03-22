// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierBase.sol";

/// @title XQuoteVerifier - X (Twitter) quote tweet verifier
/// @notice Verifier instance for X quote tweet verification.
/// @dev v3 architecture: check() lives in XQuoteVerifierSpec, not here.
///      This contract inherits VerifierBase (owner, DOMAIN_SEPARATOR, reportResult, withdrawFees)
///      and points to XQuoteVerifierSpec via spec().
contract XQuoteVerifier is VerifierBase {

    // ============ State ============

    /// @notice Maximum request_sign deadline window accepted by this verifier instance
    uint256 public constant MAX_SIGN_DEADLINE_SECONDS = 3600;

    /// @notice The XQuoteVerifierSpec contract address
    address public immutable SPEC;

    // ============ Constructor ============

    /// @param specAddress The deployed XQuoteVerifierSpec contract address
    constructor(address usdc_, address specAddress) VerifierBase(usdc_, "XQuoteVerifier", "1") {
        require(specAddress != address(0), "spec cannot be zero");
        SPEC = specAddress;
    }

    // ============ IVerifier ============

    /// @inheritdoc IVerifier
    function description() external pure override(VerifierBase) returns (string memory) {
        return
            "Verify quote-tweets on X (Twitter). Checks if a specific user quoted a given tweet. "
            "EIP-712 signed, max sign deadline 3600s.";
    }

    /// @inheritdoc IVerifier
    function spec() external view override(VerifierBase) returns (address) {
        return SPEC;
    }
}
