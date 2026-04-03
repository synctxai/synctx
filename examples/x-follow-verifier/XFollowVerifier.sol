// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierBase.sol";

/// @title XFollowVerifier - X (Twitter) 关注关系验证者
/// @notice 用于 X 关注关系验证的 Verifier 实例。
/// @dev check() 在 XFollowVerifierSpec 中，不在此处。
///      此合约继承 VerifierBase（owner、DOMAIN_SEPARATOR、reportResult、withdrawFees），
///      并通过 spec() 指向 XFollowVerifierSpec。
///
///      职责分工：
///      - XFollowVerifierSpec：定义 EIP-712 TYPEHASH，验证签名的有效性
///      - XFollowVerifier（本合约）：持有 owner、DOMAIN_SEPARATOR，提交验证结果，管理费用
///      - 链下服务：监听 VerificationRequested 事件，调用 twitterapi.io + twitter-api45
///        双源并行查询 follow 关系，调用 reportResult
contract XFollowVerifier is VerifierBase {

    // ============ 常量 ============

    /// @notice 签名时程序验证 deadline <= now + MAX_SIGN_DEADLINE_SECONDS
    uint256 public constant MAX_SIGN_DEADLINE_SECONDS = 30 days;

    // ============ 不可变量 ============

    /// @notice XFollowVerifierSpec 合约地址
    address public immutable SPEC;

    // ============ 构造函数 ============

    /// @param specAddress 已部署的 XFollowVerifierSpec 合约地址
    constructor(address specAddress) VerifierBase("XFollowVerifier", "1") {
        require(specAddress != address(0), "spec cannot be zero");
        SPEC = specAddress;
    }

    // ============ IVerifier 实现 ============

    /// @inheritdoc IVerifier
    function description() external pure override(VerifierBase) returns (string memory) {
        return
            "Verify follow relationships on X (Twitter) for campaign model. "
            "Per-campaign signature (target_user_id + fee + deadline). "
            "Dual-provider verification: twitterapi.io + twitter-api45. "
            "EIP-712 signed, max sign deadline 30 days.";
    }

    /// @inheritdoc IVerifier
    function spec() external view override(VerifierBase) returns (address) {
        return SPEC;
    }
}
