// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVerifier - 验证者合约标准接口 (v3)
/// @notice 所有验证者合约必须实现此接口。
/// @dev check() 不属于 IVerifier — 它属于 VerifierSpec 合约。
///      VerifierBase 暴露 DOMAIN_SEPARATOR（public）和 signer（public）供 Spec 的 check() 读取。
interface IVerifier {

    /// @notice 向交易合约提交验证结果
    /// @param dealContract 交易合约地址
    /// @param dealIndex 交易索引
    /// @param verificationIndex 验证槽位索引
    /// @param result 验证结果：正数=通过，负数=失败，0=不确定。
    ///        正数的含义取决于 Spec 声明的结果类型：
    ///        - 是否判断（Boolean）：仅用 1（是）/ -1（否），不允许其他值
    ///        - 打分（Score）：在 [1, maxScore] 区间内返回分数，maxScore 由 Spec 的 description() 声明（≤ 127）
    /// @param reason 人类可读的原因描述
    /// @param expectedFee 预期 USDC 费用，必须与请求签名时返回给 Trader 的 fee 一致；如果 DealContract 未支付此金额则 revert
    function reportResult(address dealContract, uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason, uint256 expectedFee) external;

    /// @notice Verifier 实例名称（用于展示）
    function name() external view returns (string memory);

    /// @notice 验证能力描述（实例级别的自我介绍）
    function description() external view returns (string memory);

    /// @notice 合约 owner（管理合约、提取费用）
    function owner() external view returns (address);

    /// @notice 签名者 EOA（签 EIP-712 报价、提交验证结果）
    function signer() external view returns (address);

    /// @notice 返回此 Verifier 实现的业务 Spec 合约地址（VerifierSpec 子合约）
    function spec() external view returns (address);

    /// @notice EIP-712 域分隔符（public，供 Spec 的 check() 读取）
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice ERC-165 接口检测
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
