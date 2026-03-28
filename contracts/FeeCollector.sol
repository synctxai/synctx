// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IERC20.sol";

/// @title FeeCollector - 协议费金库
/// @notice 接收交易合约支付的协议费。任何人都可以将累积费用转到 RECIPIENT。
/// @dev 以实际代币余额为准（包含意外转入的金额）。
///      无 owner、无 admin — 完全自动化的费用归集合约。
contract FeeCollector {
    error ZeroAddress();       // 地址为零
    error BelowThreshold();    // 余额低于归集阈值
    error TransferFailed();    // 转账失败

    event FeeSwept(address indexed recipient, uint256 amount);

    /// @notice USDC 代币地址
    address public immutable USDC;

    /// @notice 费用接收地址（最终收款方）
    address public immutable RECIPIENT;

    /// @notice 归集阈值 — 余额达到此值才允许归集，避免频繁小额转账
    uint256 public immutable SWEEP_THRESHOLD;

    constructor(address usdc, address recipient, uint256 sweepThreshold) {
        if (usdc == address(0) || recipient == address(0)) revert ZeroAddress();
        USDC = usdc;
        RECIPIENT = recipient;
        SWEEP_THRESHOLD = sweepThreshold;
    }

    /// @notice 将所有累积的 USDC 归集到 RECIPIENT
    /// @dev 任何人都可以调用，余额必须 ≥ SWEEP_THRESHOLD
    function sweepFees() external {
        uint256 vaultBalance = IERC20(USDC).balanceOf(address(this));
        if (vaultBalance < SWEEP_THRESHOLD) revert BelowThreshold();
        if (!IERC20(USDC).transfer(RECIPIENT, vaultBalance)) revert TransferFailed();
        emit FeeSwept(RECIPIENT, vaultBalance);
    }

    /// @notice 查询当前累积的 USDC 余额
    function balance() external view returns (uint256) {
        return IERC20(USDC).balanceOf(address(this));
    }
}
