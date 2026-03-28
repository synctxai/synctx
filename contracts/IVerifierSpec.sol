// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVerifierSpec - 业务验证规范合约接口
/// @notice 定义验证规范的元数据和 check 逻辑。
/// @dev 每个 VerifierSpec 定义：name/version/description + check() 用于 EIP-712 签名验证。
///      check() 通过回调从 Verifier 实例读取 DOMAIN_SEPARATOR 和 owner。
///      注意：check() 不在此接口中声明，因为每个 Spec 的参数签名不同。
interface IVerifierSpec {

    /// @notice Spec 名称（如 "XQuoteVerifierSpec"）
    function name() external pure returns (string memory);

    /// @notice Spec 版本号（如 "1.0"）
    function version() external pure returns (string memory);

    /// @notice Spec 描述 — 必须文档化 specParams 的 abi.encode 格式：参数名、类型、顺序
    function description() external pure returns (string memory);

    /// @notice 验证 EIP-712 签名的有效性
    /// @dev 每个 VerifierSpec 定义自己的 check()，带有 Spec 特定的业务参数。
    ///      基础接口不声明 check()，因为各 Spec 的参数签名不同。
    ///      示例：XQuoteVerifierSpec.check(verifierInstance, tweet_id, quoter_username, fee, deadline, sig)
    ///      示例：XFollowerQualityVerifierSpec.check(verifierInstance, username, fee, deadline, sig)
}
