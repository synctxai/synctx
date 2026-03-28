// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierSpec.sol";

/// @title XQuoteVerifierSpec - X 引用推文验证规范
/// @notice X/Twitter 引用推文验证的业务规范合约。
/// @dev 定义 check()，使用 EIP-712 签名验证。
///      签名阶段参数（createDeal 时）：tweet_id(string), quoter_username(string)
///      验证阶段参数（specParams）：abi.encode(tweet_id(string), quoter_username(string), quote_tweet_id(string))
///        — quote_tweet_id 由 claimDone 写入，createDeal 时不可用
contract XQuoteVerifierSpec is VerifierSpec {

    // ============ 常量 ============
    // EIP-712 结构体类型哈希，定义了签名时的字段名和类型。
    // Verifier 签名时使用相同的 TYPEHASH 构造 structHash。

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(string tweetId,string quoterUsername,uint256 fee,uint256 deadline)"
    );

    // ============ VerifierSpec 元数据 ============

    /// @inheritdoc VerifierSpec
    function name() external pure override returns (string memory) {
        return "X Quote Tweet Verifier Spec";
    }

    /// @inheritdoc VerifierSpec
    function version() external pure override returns (string memory) {
        return "1.0";
    }

    /// @inheritdoc VerifierSpec
    function description() external pure override returns (string memory) {
        return
            "X/Twitter quote-tweet verification spec. EIP-712 signature check. "
            "Result type: Boolean (1=yes, -1=no). "
            "check(tweet_id, quoter_username). "
            "specParams: abi.encode(tweet_id, quoter_username, quote_tweet_id).";
    }

    // ============ 签名验证 ============

    /// @notice 恢复 X 引用推文 EIP-712 签名的签名者地址
    /// @dev 构造 structHash，调用 _recoverEIP712Signer 恢复签名者。
    ///      调用方负责比对返回地址与 verifier.signer()。
    /// @param verifierInstance Verifier 合约地址（用于读取 DOMAIN_SEPARATOR）
    /// @param tweet_id 要验证的推文 ID
    /// @param quoter_username 引用者的 X/Twitter 用户名
    /// @param fee 验证费用（USDC，6 位小数）
    /// @param deadline 签名过期时间（Unix 秒）
    /// @param sig EIP-712 签名
    /// @return 签名者地址
    function check(
        address verifierInstance,
        string calldata tweet_id,
        string calldata quoter_username,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(
            VERIFY_TYPEHASH,
            keccak256(bytes(tweet_id)),
            keccak256(bytes(quoter_username)),
            fee,
            deadline
        ));

        return _recoverEIP712Signer(verifierInstance, structHash, deadline, sig);
    }
}
