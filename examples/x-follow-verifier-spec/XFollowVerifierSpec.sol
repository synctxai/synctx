// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VerifierSpec.sol";

/// @title XFollowVerifierSpec - X Follow 验证规范
/// @notice X/Twitter 关注关系验证的业务规范合约。
/// @dev 定义 check()，使用 EIP-712 签名验证。
///      签名阶段参数（createDeal 时）：follower_username(string), target_username(string)
///      验证阶段参数（specParams）：abi.encode(follower_username(string), target_username(string))
///      链下验证使用 twitterapi.io + twitter-api45 双源认证 follow 关系
contract XFollowVerifierSpec is VerifierSpec {

    // ============ 常量 ============

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(string followerUsername,string targetUsername,uint256 fee,uint256 deadline)"
    );

    // ============ VerifierSpec 元数据 ============

    /// @inheritdoc VerifierSpec
    function name() external pure override returns (string memory) {
        return "X Follow Verifier Spec";
    }

    /// @inheritdoc VerifierSpec
    function version() external pure override returns (string memory) {
        return "1.0";
    }

    /// @inheritdoc VerifierSpec
    function description() external pure override returns (string memory) {
        return
            "X/Twitter follow verification spec. EIP-712 signature check. "
            "Result type: Boolean (1=yes, -1=no). "
            "check(follower_username, target_username). "
            "specParams: abi.encode(follower_username, target_username). "
            "Off-chain verification uses dual providers: twitterapi.io + twitter-api45 (RapidAPI).";
    }

    // ============ 签名验证 ============

    /// @notice 恢复 X Follow EIP-712 签名的签名者地址
    /// @param verifierInstance Verifier 合约地址（用于读取 DOMAIN_SEPARATOR）
    /// @param follower_username 关注者的 X/Twitter 用户名
    /// @param target_username 被关注者的 X/Twitter 用户名
    /// @param fee 验证费用（USDC，6 位小数）
    /// @param deadline 签名过期时间（Unix 秒）
    /// @param sig EIP-712 签名
    /// @return 签名者地址
    function check(
        address verifierInstance,
        string calldata follower_username,
        string calldata target_username,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(
            VERIFY_TYPEHASH,
            keccak256(bytes(follower_username)),
            keccak256(bytes(target_username)),
            fee,
            deadline
        ));

        return _recoverEIP712Signer(verifierInstance, structHash, deadline, sig);
    }
}
