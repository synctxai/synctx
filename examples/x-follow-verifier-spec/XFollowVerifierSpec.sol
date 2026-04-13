// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierSpec.sol";

/// @title XFollowVerifierSpec - X Follow Verification Spec (Campaign Model)
/// @notice Business specification contract for X/Twitter follow relationship verification.
/// @dev Defines check() with EIP-712 signature verification.
///      check signature params (per-campaign): target_user_id(uint64)
///      specParams (per-claim verification): abi.encode(target_user_id(uint64))
///      Follower identity resolved off-chain by verifier
contract XFollowVerifierSpec is VerifierSpec {

    // ============ Constants ============
    // Signature is per-campaign: Verifier commits to verifying follow relationships for a given target_user_id.
    // follower_user_id is not in the signature or specParams (resolved via Platform API).

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(uint64 targetUserId,uint256 fee,uint256 deadline)"
    );

    // ============ VerifierSpec Metadata ============

    /// @inheritdoc VerifierSpec
    function name() external pure override returns (string memory) {
        return "X(Twitter) Follow Verifier Spec";
    }

    /// @inheritdoc VerifierSpec
    function version() external pure override returns (string memory) {
        return "1.0";
    }

    /// @inheritdoc VerifierSpec
    function description() external pure override returns (string memory) {
        return
            "Verifies whether a given address's bound X(Twitter) account is following target_user_id. "
            "The follower's X identity is resolved via on-chain twitter binding; the verifier performs the follow check off-chain. "
            "EIP-712 signature check. Result type: 1=pass, -1=fail, 0=inconclusive. "
            "request_sign params: {target_user_id}. "
            "specParams: abi.encode(target_user_id).";
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
