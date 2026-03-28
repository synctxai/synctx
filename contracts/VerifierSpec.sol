// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVerifier.sol";

/// @title VerifierSpec - 业务验证规范合约基类
/// @notice 所有 VerifierSpec 合约必须继承此抽象合约。
/// @dev 提供元数据接口（name/version/description）和 EIP-712 签名验证共享逻辑。
///      子合约只需定义 TYPEHASH、check() 参数和元数据覆盖。
///
///      继承示例：
///        abstract contract VerifierSpec
///          └── XQuoteVerifierSpec  （定义 TYPEHASH + check + 元数据）
abstract contract VerifierSpec {

    // ============ 错误 ============

    error SignatureExpired();        // 签名已过期
    error InvalidSignatureLength();  // 签名长度无效（必须 65 字节）
    error InvalidSignatureV();       // 签名 v 值无效
    error InvalidSignature();        // ecrecover 返回零地址
    error SignatureSMalleability();  // 签名 s 值过高（EIP-2 防可塑性）

    // ============ 元数据（子合约必须覆盖） ============

    /// @notice Spec 名称（如 "X Quote Tweet Verifier Spec"）
    function name() external pure virtual returns (string memory);

    /// @notice Spec 版本号（如 "1.0"）
    function version() external pure virtual returns (string memory);

    /// @notice Spec 描述 — 必须文档化 specParams 的 abi.encode 格式：参数名、类型、顺序。
    ///         必须声明结果类型：
    ///         - 是否判断（Boolean）：result 仅用 1（是）/ -1（否）
    ///         - 打分（Score）：result 在 [1, maxScore] 区间，需声明 maxScore（≤ 127）
    function description() external pure virtual returns (string memory);

    // ============ EIP-712 共享逻辑 ============

    /// @dev 验证 EIP-712 签名：构造 digest，恢复签名者，比对 verifier.owner()
    /// @param verifierInstance Verifier 合约地址（读取 DOMAIN_SEPARATOR 和 owner）
    /// @param structHash 由子合约用 TYPEHASH + 业务参数构造的 structHash
    /// @param deadline 签名过期时间（Unix 秒）
    /// @param sig EIP-712 签名（65 字节）
    /// @return 签名是否有效
    function _verifyEIP712(
        address verifierInstance,
        bytes32 structHash,
        uint256 deadline,
        bytes calldata sig
    ) internal view returns (bool) {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 domainSeparator = IVerifier(verifierInstance).DOMAIN_SEPARATOR();
        address owner_ = IVerifier(verifierInstance).owner();

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signer = _recoverSigner(digest, sig);
        return signer == owner_;
    }

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
