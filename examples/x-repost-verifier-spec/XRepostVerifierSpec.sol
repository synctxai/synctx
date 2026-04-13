// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierSpec.sol";

/// @title XRepostVerifierSpec - X(Twitter) Repost Verification Spec
/// @notice Verification spec for X(Twitter) repost. A repost is satisfied by EITHER a
///         native repost(retweet) OR a quote tweet from the reposter's bound X(Twitter) account.
///         There is no time window — previously-posted reposts count.
/// @dev Defines check() with EIP-712 signature verification.
///      Verify struct binds the EIP-712 signature to a specific reposter address so the
///      verifier's signed quote cannot be replayed on a different reposter.
///      check signature params: tweet_id(string), reposter_address(address)
///      specParams: abi.encode(tweet_id(string), reposter_address(address))
contract XRepostVerifierSpec is VerifierSpec {

    // ============ Constants ============
    // EIP-712 struct type hash, defines the field names and types used during signing.
    // Verifier uses the same TYPEHASH to construct structHash when signing.
    //
    // NOTE: reposter_address is signed into the struct. This binds the signature
    // cryptographically to a specific reposter so the verifier's signed quote cannot
    // be replayed on a different reposter.

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(string tweetId,address reposterAddress,uint256 fee,uint256 deadline)"
    );

    // ============ VerifierSpec Metadata ============

    /// @inheritdoc VerifierSpec
    function name() external pure override returns (string memory) {
        return "X(Twitter) Repost Verifier Spec";
    }

    /// @inheritdoc VerifierSpec
    function version() external pure override returns (string memory) {
        return "1.0";
    }

    /// @inheritdoc VerifierSpec
    function description() external pure override returns (string memory) {
        return
            "Verifies whether reposter_address's bound X(Twitter) account has reposted a given tweet via native repost(retweet) OR quote tweet. "
            "EIP-712 signature check. Result type: 1=pass, -1=fail, 0=inconclusive. "
            "request_sign params: {tweet_id, reposter_address}. "
            "specParams: abi.encode(tweet_id, reposter_address).";
    }

    // ============ Signature Verification ============

    /// @notice Recover the signer address from an X repost EIP-712 signature
    /// @dev Constructs structHash, calls _recoverEIP712Signer to recover the signer.
    ///      Caller is responsible for comparing the returned address with verifier.signer().
    /// @param verifierInstance Verifier contract address (for reading DOMAIN_SEPARATOR)
    /// @param tweet_id The tweet ID to be reposted
    /// @param reposter_address The reposter address the verifier's quote is bound to
    /// @param fee Verification fee (USDC, 6 decimals)
    /// @param deadline Signature expiration timestamp (Unix seconds)
    /// @param sig EIP-712 signature
    /// @return Signer address
    function check(
        address verifierInstance,
        string calldata tweet_id,
        address reposter_address,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(
            VERIFY_TYPEHASH,
            keccak256(bytes(tweet_id)),
            reposter_address,
            fee,
            deadline
        ));

        return _recoverEIP712Signer(verifierInstance, structHash, deadline, sig);
    }
}
