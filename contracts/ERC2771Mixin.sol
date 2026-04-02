// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ERC2771Mixin - 可选的 meta-transaction 支持
/// @dev 独立于 IDeal/DealBase 体系，业务合约按需继承。
///      不继承此 mixin 的合约完全不受影响。
///      trustedForwarder 只能设置一次，设置后不可更改。
abstract contract ERC2771Mixin {
    error NotForwarderAdmin();
    error ForwarderAlreadySet();

    event TrustedForwarderSet(address indexed forwarder);

    /// @dev 部署者地址，用于一次性设置 trustedForwarder
    address private _forwarderAdmin;

    /// @notice 可信转发器地址（address(0) 表示禁用免 gas）
    address public trustedForwarder;

    constructor() {
        _forwarderAdmin = msg.sender;
    }

    /// @dev Clone 初始化时调用（constructor 不执行时的替代路径）
    /// @param forwarder 可信转发器地址
    /// @param admin 转发器管理员（address(0) 表示 forwarder 已锁定）
    function _initForwarder(address forwarder, address admin) internal {
        trustedForwarder = forwarder;
        _forwarderAdmin = admin;
    }

    /// @notice 一次性设置可信转发器地址，设置后不可更改
    /// @param forwarder 转发器地址，address(0) 表示禁用
    function setTrustedForwarder(address forwarder) external {
        if (msg.sender != _forwarderAdmin) revert NotForwarderAdmin();
        if (trustedForwarder != address(0)) revert ForwarderAlreadySet();
        trustedForwarder = forwarder;
        _forwarderAdmin = address(0);
        emit TrustedForwarderSet(forwarder);
    }

    /// @dev 当 msg.sender 是 Trusted Forwarder 时，从 calldata 尾部提取真实 sender。
    ///      否则回退到 msg.sender（兼容直接调用）。
    function _msgSender() internal view returns (address sender) {
        if (msg.sender == trustedForwarder && msg.data.length >= 20) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    /// @notice 查询指定地址是否为可信转发器
    function isTrustedForwarder(address forwarder) external view returns (bool) {
        return forwarder == trustedForwarder;
    }
}
