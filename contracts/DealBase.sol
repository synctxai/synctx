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

    // ===================== Deal 索引计数器 =====================

    /// @dev 下一个 deal 的索引，由 _recordStart 自增
    uint256 private _nextDealIndex;

    /// @dev 记录新交易创建
    /// @param traders 参与交易的地址数组
    /// @param verifiers 验证者地址数组（无验证则传空数组）
    /// @return dealIndex 新交易的索引（自增前的值）
    function _recordStart(address[] memory traders, address[] memory verifiers) internal returns (uint256 dealIndex) {
        dealIndex = _nextDealIndex++;
        emit DealCreated(dealIndex, traders, verifiers);
    }

    /// @dev 发出 Phase 变更事件
    /// @param dealIndex 交易索引
    /// @param toPhase 目标 phase：2=Active, 3=Success, 4=Failed, 5=Cancelled
    function _emitPhaseChanged(uint256 dealIndex, uint8 toPhase) internal {
        emit DealPhaseChanged(dealIndex, toPhase);
    }

    /// @dev 发出状态变更通知
    function _emitStateChanged(uint256 dealIndex, uint8 stateIndex) internal {
        emit DealStateChanged(dealIndex, stateIndex);
    }

    /// @dev 发出违约标记
    function _emitViolated(uint256 dealIndex, address violator) internal {
        emit DealViolated(dealIndex, violator);
    }

    // ===================== 抽象方法 =====================
    // 子合约必须覆盖以下所有方法。
    // onVerificationResult 默认 revert — 不使用验证的合约无需覆盖。

    function name() external pure virtual returns (string memory);

    function description() external pure virtual returns (string memory);

    function tags() external pure virtual returns (string[] memory);

    function version() external pure virtual returns (string memory);

    function instruction() external view virtual returns (string memory);

    function phase(uint256 dealIndex) external view virtual returns (uint8);

    function dealStatus(uint256 dealIndex) external view virtual returns (uint8);

    function dealExists(uint256 dealIndex) external view virtual returns (bool);

    function protocolFeePolicy() external view virtual returns (string memory);

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
    function onVerificationResult(uint256, uint256, int8, string calldata) external virtual {
        revert("not implemented");
    }
}
