// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVerifierSpec.sol";
import "./IVerifier.sol";

/// @title XQuoteVerifierSpec - X Quote Tweet Verification Spec
/// @notice Business specification contract for X/Twitter quote tweet verification.
/// @dev Defines check() with EIP-712 signature verification.
///      check signature params (createDeal phase): tweet_id(string), quoter_username(string)
///      specParams (verification phase): abi.encode(tweet_id(string), quoter_username(string), quote_tweet_id(string))
///        — quote_tweet_id is written by claimDone, not available at createDeal time
contract XQuoteVerifierSpec is IVerifierSpec {

    // ============ Errors ============

    error SignatureExpired();
    error InvalidSignatureLength();
    error InvalidSignatureV();
    error InvalidSignature();
    error SignatureSMalleability();

    // ============ Constants ============

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(string tweetId,string quoterUsername,uint256 fee,uint256 deadline)"
    );

    // ============ IVerifierSpec Implementation ============

    /// @inheritdoc IVerifierSpec
    function name() external pure override returns (string memory) {
        return "XQuoteVerifierSpec";
    }

    /// @inheritdoc IVerifierSpec
    function version() external pure override returns (string memory) {
        return "1.0";
    }

    /// @inheritdoc IVerifierSpec
    function description() external pure override returns (string memory) {
        return
            "Verifies X/Twitter quote tweets. "
            "check params: string tweet_id, string quoter_username. "
            "specParams (for verification): abi.encode(string tweet_id, string quoter_username, string quote_tweet_id).";
    }

    /// @notice Verify EIP-712 signature for X quote tweet verification
    /// @param verifierInstance The verifier contract address (for DOMAIN_SEPARATOR and owner lookup)
    /// @param tweet_id The tweet ID to verify
    /// @param quoter_username The quoter's X/Twitter username
    /// @param fee Verification fee (USDC, 6 decimals)
    /// @param deadline Signature expiration timestamp (Unix)
    /// @param sig EIP-712 signature
    /// @return Whether the signature is valid
    function check(
        address verifierInstance,
        string calldata tweet_id,
        string calldata quoter_username,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (bool) {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(abi.encode(
            VERIFY_TYPEHASH,
            keccak256(bytes(tweet_id)),
            keccak256(bytes(quoter_username)),
            fee,
            deadline
        ));

        bytes32 domainSeparator = IVerifier(verifierInstance).DOMAIN_SEPARATOR();
        address owner_ = IVerifier(verifierInstance).owner();

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signer = _recoverSigner(digest, sig);
        return signer == owner_;
    }

    // ============ Internal Functions ============

    /// @dev Recover signer address from EIP-712 digest.
    ///      Enforces low-s value (EIP-2) to prevent signature malleability.
    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignatureV();

        // Reject high s-values to prevent signature malleability (EIP-2)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert SignatureSMalleability();
        }

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }
}
