// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierSpec.sol";

/// @title XQuoteVerifierSpec - X Quote Tweet Verification Spec
/// @notice Business specification contract for X/Twitter quote tweet verification.
/// @dev Defines check() with EIP-712 signature verification.
///      check signature params (createDeal phase): tweet_id(string), quoter_user_id(uint64)
///      specParams (verification phase): abi.encode(tweet_id(string), quoter_user_id(uint64), quote_tweet_id(string))
///        — quote_tweet_id is written by claimDone, not available at createDeal time
contract XQuoteVerifierSpec is VerifierSpec {

    // ============ Constants ============
    // EIP-712 struct type hash, defines the field names and types used during signing.
    // Verifier uses the same TYPEHASH to construct structHash when signing.

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(string tweetId,uint64 quoterUserId,uint256 fee,uint256 deadline)"
    );

    // ============ VerifierSpec Metadata ============

    /// @inheritdoc VerifierSpec
    function name() external pure override returns (string memory) {
        return "X Quote Tweet Verifier Spec";
    }

    /// @inheritdoc VerifierSpec
    function version() external pure override returns (string memory) {
        return "2.0";
    }

    /// @inheritdoc VerifierSpec
    function description() external pure override returns (string memory) {
        return
            "X/Twitter quote-tweet verification spec. EIP-712 signature check. "
            "Result type: Boolean (1=yes, -1=no). "
            "check(tweet_id, quoter_user_id). "
            "specParams: abi.encode(tweet_id, quoter_user_id, quote_tweet_id).";
    }

    // ============ Signature Verification ============

    /// @notice Recover the signer address from an X quote tweet EIP-712 signature
    /// @dev Constructs structHash, calls _recoverEIP712Signer to recover the signer.
    ///      Caller is responsible for comparing the returned address with verifier.signer().
    /// @param verifierInstance Verifier contract address (for reading DOMAIN_SEPARATOR)
    /// @param tweet_id The tweet ID to verify
    /// @param quoter_user_id Quoter's X/Twitter immutable user_id
    /// @param fee Verification fee (USDC, 6 decimals)
    /// @param deadline Signature expiration timestamp (Unix seconds)
    /// @param sig EIP-712 signature
    /// @return Signer address
    function check(
        address verifierInstance,
        string calldata tweet_id,
        uint64 quoter_user_id,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(
            VERIFY_TYPEHASH,
            keccak256(bytes(tweet_id)),
            quoter_user_id,
            fee,
            deadline
        ));

        return _recoverEIP712Signer(verifierInstance, structHash, deadline, sig);
    }
}
