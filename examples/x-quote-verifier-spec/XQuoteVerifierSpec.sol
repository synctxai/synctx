// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVerifierSpec.sol";
import "./IVerifier.sol";

/// @title XQuoteVerifierSpec - X 引用推文验证规范
/// @notice X/Twitter 引用推文验证的业务规范合约。
/// @dev 定义 check()，使用 EIP-712 签名验证。
///      签名阶段参数（createDeal 时）：tweet_id(string), quoter_username(string)
///      验证阶段参数（specParams）：abi.encode(tweet_id(string), quoter_username(string), quote_tweet_id(string))
///        — quote_tweet_id 由 claimDone 写入，createDeal 时不可用
contract XQuoteVerifierSpec is IVerifierSpec {

    // ============ 错误 ============

    error SignatureExpired();        // 签名已过期
    error InvalidSignatureLength();  // 签名长度无效（必须 65 字节）
    error InvalidSignatureV();       // 签名 v 值无效
    error InvalidSignature();        // ecrecover 返回零地址
    error SignatureSMalleability();  // 签名 s 值过高（EIP-2 防可塑性）

    // ============ 常量 ============
    // EIP-712 结构体类型哈希，定义了签名时的字段名和类型。
    // Verifier 签名时使用相同的 TYPEHASH 构造 structHash。

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(string tweetId,string quoterUsername,uint256 fee,uint256 deadline)"
    );

    // ============ IVerifierSpec 实现 ============

    /// @inheritdoc IVerifierSpec
    function name() external pure override returns (string memory) {
        return "X Quote Tweet Verifier Spec";
    }

    /// @inheritdoc IVerifierSpec
    function version() external pure override returns (string memory) {
        return "1.0";
    }

    /// @inheritdoc IVerifierSpec
    function description() external pure override returns (string memory) {
        return
            "X/Twitter quote-tweet verification spec. EIP-712 signature check. "
            "check(tweet_id, quoter_username). "
            "specParams: abi.encode(tweet_id, quoter_username, quote_tweet_id).";
    }

    // ============ 签名验证 ============

    /// @notice 验证 X 引用推文的 EIP-712 签名
    /// @dev 流程：
    ///      1. 检查签名是否过期（deadline）
    ///      2. 用 TYPEHASH + 业务参数构造 structHash
    ///      3. 从 Verifier 实例读取 DOMAIN_SEPARATOR 和 owner
    ///      4. 构造 EIP-712 digest 并 ecrecover 恢复签名者
    ///      5. 验证签名者 == Verifier.owner()
    /// @param verifierInstance Verifier 合约地址（用于读取 DOMAIN_SEPARATOR 和 owner）
    /// @param tweet_id 要验证的推文 ID
    /// @param quoter_username 引用者的 X/Twitter 用户名
    /// @param fee 验证费用（USDC，6 位小数）
    /// @param deadline 签名过期时间（Unix 秒）
    /// @param sig EIP-712 签名
    /// @return 签名是否有效
    function check(
        address verifierInstance,
        string calldata tweet_id,
        string calldata quoter_username,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (bool) {
        if (block.timestamp > deadline) revert SignatureExpired();

        // 构造 EIP-712 structHash：对字符串参数取 keccak256，数值参数直接 encode
        bytes32 structHash = keccak256(abi.encode(
            VERIFY_TYPEHASH,
            keccak256(bytes(tweet_id)),
            keccak256(bytes(quoter_username)),
            fee,
            deadline
        ));

        // 从 Verifier 实例读取 EIP-712 域分隔符和 owner 地址
        bytes32 domainSeparator = IVerifier(verifierInstance).DOMAIN_SEPARATOR();
        address owner_ = IVerifier(verifierInstance).owner();

        // 构造完整的 EIP-712 digest 并恢复签名者
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signer = _recoverSigner(digest, sig);
        return signer == owner_;
    }

    // ============ 内部函数 ============

    /// @dev 从 EIP-712 digest 恢复签名者地址。
    ///      强制 low-s 值（EIP-2）以防止签名可塑性攻击。
    ///      签名可塑性：同一消息可以有两个有效签名（s 和 n-s），
    ///      low-s 约束确保只有一个有效签名，防止第三方"翻转"签名。
    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;

        // 从 calldata 中提取 r, s, v（比 abi.decode 更省 gas）
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        // 兼容 v=0/1（某些钱包）和 v=27/28（标准）
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignatureV();

        // 拒绝高 s 值以防止签名可塑性（EIP-2）
        // secp256k1 曲线阶的一半 = 0x7FFFFFFF...681B20A0
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert SignatureSMalleability();
        }

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }
}
