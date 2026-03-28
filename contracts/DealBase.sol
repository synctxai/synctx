// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IDeal.sol";

/// @title DealBase - 交易合约抽象基类
/// @notice 实现 IDeal。子合约继承并覆盖所有抽象方法。
/// @dev 刻意保持轻量 — 不定义 State 枚举、Deal 结构体或存储。
///      不同类型的交易合约有截然不同的状态机和数据模型。
///      安全原则：无 owner、无 admin、无 proxy、无 selfdestruct、无 delegatecall。
///      信任来自代码透明度和审计，而非特权角色。
abstract contract DealBase is IDeal {

    // ===================== ERC165 =====================
    // ERC-165 用于平台识别此合约是否实现了 IDeal 接口。

    bytes4 private constant _INTERFACE_ID =
        type(IDeal).interfaceId;

    /// @dev IERC165 interfaceId = bytes4(keccak256("supportsInterface(bytes4)"))
    bytes4 private constant _IERC165_ID = 0x01ffc9a7;

    /// @dev 无 virtual → 子合约不可覆盖
    /// @notice ERC165：查询此合约是否实现了指定接口
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == _INTERFACE_ID
            || interfaceId == _IERC165_ID;
    }

    // ===================== 接口版本 =====================

    /// @dev 无 virtual → 子合约不可覆盖
    function standard() external pure returns (uint8) {
        return 1;
    }

    // ===================== 防篡改统计 =====================
    // 使用 private 存储，子合约无法直接读写。
    // 只能通过 internal 辅助函数递增，保证统计数据的真实性。
    // 这些数据是平台信誉系统的基础。

    /// @dev private → 子合约无法直接读写
    uint256 private _startCount;
    uint256 private _activatedCount;
    uint256 private _endCount;
    uint256 private _disputeCount;

    /// @dev 记录新交易创建
    /// @param traders 参与交易的地址数组
    /// @param verifiers 验证者地址数组（无验证则传空数组）
    /// @return dealIndex 新交易的索引（自增前的值）
    function _recordStart(address[] memory traders, address[] memory verifiers) internal returns (uint256 dealIndex) {
        dealIndex = _startCount++;
        emit DealCreated(dealIndex, traders, verifiers);
    }

    /// @dev 记录交易激活（所有参与方已确认）
    /// @param dealIndex 交易索引
    function _recordActivated(uint256 dealIndex) internal {
        _activatedCount++;
        emit DealActivated(dealIndex);
    }

    /// @dev 记录交易正常结束
    /// @param dealIndex 交易索引
    function _recordEnd(uint256 dealIndex) internal {
        _endCount++;
        emit DealEnded(dealIndex);
    }

    /// @dev 记录交易以争议结束
    function _recordDispute(uint256 dealIndex) internal {
        _disputeCount++;
        emit DealDisputed(dealIndex);
    }

    /// @dev 记录交易取消（激活前，不影响统计计数）
    /// @param dealIndex 交易索引
    function _recordCancelled(uint256 dealIndex) internal {
        emit DealCancelled(dealIndex);
    }

    /// @dev 发出状态变更通知
    function _emitStateChanged(uint256 dealIndex, uint8 stateIndex) internal {
        emit DealStateChanged(dealIndex, stateIndex);
    }

    /// @dev 发出违约标记
    function _emitViolated(uint256 dealIndex, address violator) internal {
        emit DealViolated(dealIndex, violator);
    }

    // ===================== 统计查询 =====================
    // 无 virtual → 子合约不可篡改返回值

    function startCount() external view returns (uint256) {
        return _startCount;
    }

    function activatedCount() external view returns (uint256) {
        return _activatedCount;
    }

    function endCount() external view returns (uint256) {
        return _endCount;
    }

    function disputeCount() external view returns (uint256) {
        return _disputeCount;
    }

    // ===================== 抽象方法 =====================
    // 子合约必须覆盖以下所有方法。
    // onReportResult 默认 revert — 不使用验证的合约无需覆盖。

    function name() external pure virtual returns (string memory);

    function description() external pure virtual returns (string memory);

    function tags() external pure virtual returns (string[] memory);

    function version() external pure virtual returns (string memory);

    function instruction() external view virtual returns (string memory);

    function phase(uint256 dealIndex) external view virtual returns (uint8);

    function dealStatus(uint256 dealIndex) external view virtual returns (uint8);

    function dealExists(uint256 dealIndex) external view virtual returns (bool);

    function protocolFee() external view virtual returns (uint96);

    function requiredSpecs() external view virtual returns (address[] memory);

    function verificationParams(uint256 dealIndex, uint256 verificationIndex)
        external view virtual returns (
            address verifier,
            uint256 fee,
            uint256 deadline,
            bytes memory sig,
            bytes memory specParams
        );

    function requestVerification(uint256 dealIndex, uint256 verificationIndex) external virtual;

    /// @dev 子合约必须覆盖以处理验证结果。默认 revert，不使用验证的合约无需覆盖。
    function onReportResult(uint256, uint256, int8, string calldata) external virtual {
        revert("not implemented");
    }
}
