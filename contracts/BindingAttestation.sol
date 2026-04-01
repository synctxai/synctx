// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BindingAttestation - Platform 绑定证明验证合约
/// @notice 统一验证 Platform 签发的 (address, userId) 绑定签名。
///         所有需要 Twitter 绑定的 Deal 合约调用本合约的 verify()，
///         不再各自实现 _verifyBinding()。
///
/// @dev 安全模型：
///   - platformSigner 是 Platform 用于签发 Binding Attestation 的 EOA 地址
///   - 密钥轮换：owner 调用 setPlatformSigner() 更新，所有旧签名自动失效
///   - 所有权：Ownable2Step，防止误转
contract BindingAttestation {

    // ===================== 状态 =====================

    address public owner;
    address public pendingOwner;
    address public platformSigner;

    // ===================== 事件 =====================

    event PlatformSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ===================== 错误 =====================

    error ZeroAddress();
    error NotOwner();
    error NotPendingOwner();

    // ===================== 构造函数 =====================

    /// @param platformSigner_ Platform 签名 EOA 地址
    constructor(address platformSigner_) {
        if (platformSigner_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        platformSigner = platformSigner_;
        emit OwnershipTransferred(address(0), msg.sender);
        emit PlatformSignerUpdated(address(0), platformSigner_);
    }

    // ===================== 验签 =====================

    /// @notice 验证 Platform 对 (address, userId) 的 eth_sign 签名
    /// @param addr  被绑定的 EVM 地址
    /// @param userId Twitter 不可变 user_id
    /// @param sig   Platform 对 keccak256(abi.encodePacked(addr, userId)) 的签名（65 字节）
    /// @return true 当且仅当签名有效且签名者 == platformSigner
    function verify(address addr, uint64 userId, bytes calldata sig) external view returns (bool) {
        bytes32 hash = keccak256(abi.encodePacked(addr, userId));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        if (sig.length != 65) return false;

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return false;
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return false;

        address recovered = ecrecover(ethHash, v, r, s);
        return recovered == platformSigner;
    }

    // ===================== 管理函数 =====================

    /// @notice 更新 platformSigner（密钥轮换）
    /// @dev 更新后所有旧签名自动失效，用户需重新获取 attestation
    function setPlatformSigner(address newSigner) external {
        _onlyOwner();
        if (newSigner == address(0)) revert ZeroAddress();
        address old = platformSigner;
        platformSigner = newSigner;
        emit PlatformSignerUpdated(old, newSigner);
    }

    // ===================== Ownable2Step =====================

    function transferOwnership(address newOwner) external {
        _onlyOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address old = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, msg.sender);
    }

    // ===================== 内部 =====================

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }
}
