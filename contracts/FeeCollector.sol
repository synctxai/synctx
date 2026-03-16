// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FeeCollector - Protocol fee treasury
/// @notice Receives protocol fees from escrow contracts. Anyone can sweep to RECIPIENT.
/// @dev Uses real token balance as source of truth (includes accidental transfers).
contract FeeCollector {
    error ZeroAddress();
    error BelowThreshold();
    error TransferFailed();

    event FeeSwept(address indexed recipient, uint256 amount);

    address public immutable USDC;
    address public immutable RECIPIENT;
    uint256 public immutable SWEEP_THRESHOLD;

    constructor(address usdc, address recipient, uint256 sweepThreshold) {
        if (usdc == address(0) || recipient == address(0)) revert ZeroAddress();
        USDC = usdc;
        RECIPIENT = recipient;
        SWEEP_THRESHOLD = sweepThreshold;
    }

    function sweepFees() external {
        uint256 vaultBalance = IUSDCFeeCollector(USDC).balanceOf(address(this));
        if (vaultBalance < SWEEP_THRESHOLD) revert BelowThreshold();
        if (!IUSDCFeeCollector(USDC).transfer(RECIPIENT, vaultBalance)) revert TransferFailed();
        emit FeeSwept(RECIPIENT, vaultBalance);
    }

    function balance() external view returns (uint256) {
        return IUSDCFeeCollector(USDC).balanceOf(address(this));
    }
}

interface IUSDCFeeCollector {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
