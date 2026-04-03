// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierSpec.sol";

/// @title XFollowVerifierSpec - X Follow Verification Spec (Campaign Model)
/// @notice Business specification contract for X/Twitter follow relationship verification.
/// @dev Defines check() with EIP-712 signature verification.
///      check signature params (per-campaign): target_user_id(uint64)
///      specParams (per-claim verification): abi.encode(follower_user_id(uint64), target_user_id(uint64))
///      Off-chain verification queries external follow-relationship providers
contract XFollowVerifierSpec is VerifierSpec {

    // ============ Constants ============
    // Signature is per-campaign: Verifier commits to verifying follow relationships for a given target_user_id.
    // follower_user_id is not in the signature (each claim has a different follower, provided by B's Binding Attestation).

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(uint64 targetUserId,uint256 fee,uint256 deadline)"
    );

    // ============ VerifierSpec Metadata ============

    /// @inheritdoc VerifierSpec
    function name() external pure override returns (string memory) {
        return "X Follow Verifier Spec";
    }

    /// @inheritdoc VerifierSpec
    function version() external pure override returns (string memory) {
        return "3.0";
    }

    /// @inheritdoc VerifierSpec
    function description() external pure override returns (string memory) {
        return
            "X/Twitter follow verification spec (campaign model). EIP-712 signature check. "
            "Result type: Boolean (1=yes, -1=no). "
            "Signature: per-campaign, signs target_user_id + fee + deadline. "
            "specParams: abi.encode(follower_user_id, target_user_id).";
    }

    // ============ Signature Verification ============

    /// @notice Recover the signer address from an X Follow campaign EIP-712 signature
    /// @param verifierInstance Verifier contract address (for reading DOMAIN_SEPARATOR)
    /// @param target_user_id Target's X/Twitter immutable user_id
    /// @param fee Per-verification fee (USDC, 6 decimals)
    /// @param deadline Signature expiration timestamp (Unix seconds), must be >= campaign deadline
    /// @param sig EIP-712 signature
    /// @return Signer address
    function check(
        address verifierInstance,
        uint64 target_user_id,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(
            VERIFY_TYPEHASH,
            target_user_id,
            fee,
            deadline
        ));

        return _recoverEIP712Signer(verifierInstance, structHash, deadline, sig);
    }
}
