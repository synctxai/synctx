// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierBase.sol";

/// @title XQuoteVerifier - X (Twitter) 引用推文验证者
/// @notice 用于 X 引用推文验证的 Verifier 实例。
/// @dev check() 在 XQuoteVerifierSpec 中，不在此处。
///      此合约继承 VerifierBase（owner、DOMAIN_SEPARATOR、reportResult、withdrawFees），
///      并通过 spec() 指向 XQuoteVerifierSpec。
///
///      职责分工：
///      - XQuoteVerifierSpec：定义 EIP-712 TYPEHASH，验证签名的有效性
///      - XQuoteVerifier（本合约）：持有 owner、DOMAIN_SEPARATOR，提交验证结果，管理费用
///      - 链下服务：监听 VerificationRequested 事件，调用 X API 执行实际验证，调用 reportResult
contract XQuoteVerifier is VerifierBase {

    // ============ 常量 ============

    /// @notice 签名时程序验证 deadline ≤ now + MAX_SIGN_DEADLINE_SECONDS
    /// @dev 链上不额外校验 — createDeal 的签名验证已隐式保证 deadline 在此范围内。
    ///      此常量为链下程序提供标准参数。
    uint256 public constant MAX_SIGN_DEADLINE_SECONDS = 3600;

    // ============ 不可变量 ============

    /// @notice XQuoteVerifierSpec 合约地址
    address public immutable SPEC;

    // ============ 构造函数 ============

    /// @param usdc_ USDC 代币地址
    /// @param specAddress 已部署的 XQuoteVerifierSpec 合约地址
    constructor(address usdc_, address specAddress) VerifierBase(usdc_, "XQuoteVerifier", "1") {
        require(specAddress != address(0), "spec cannot be zero");
        SPEC = specAddress;
    }

    // ============ IVerifier 实现 ============

    /// @inheritdoc IVerifier
    function description() external pure override(VerifierBase) returns (string memory) {
        return
            "Verify quote-tweets on X (Twitter). Checks if a specific user quoted a given tweet. "
            "EIP-712 signed, max sign deadline 3600s.";
    }

    /// @inheritdoc IVerifier
    function spec() external view override(VerifierBase) returns (address) {
        return SPEC;
    }
}
