// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IERC20.sol";
import "./Initializable.sol";

/// @title FeeCollector - Protocol fee treasury
/// @notice Receives protocol fees from deal contracts. Anyone can sweep accumulated fees to RECIPIENT.
/// @dev Uses real token balance as source of truth (includes accidental transfers).
///      No owner, no admin — a fully automated fee collection contract.
contract FeeCollector is Initializable {
    error ZeroAddress();       // Address is zero
    error BelowThreshold();    // Balance below sweep threshold
    error TransferFailed();    // Transfer failed
    error FeeTokenNotSet();    // feeToken not set

    event FeeSwept(address indexed recipient, uint256 amount);

    /// @notice Fee recipient address (final payee)
    address public immutable RECIPIENT;

    /// @notice Sweep threshold — balance must reach this value before sweeping, to avoid frequent small transfers
    uint256 public immutable SWEEP_THRESHOLD;

    constructor(address recipient, uint256 sweepThreshold) {
        _setInitializer();
        if (recipient == address(0)) revert ZeroAddress();
        RECIPIENT = recipient;
        SWEEP_THRESHOLD = sweepThreshold;
    }

    /// @notice Sweep all accumulated fees to RECIPIENT
    /// @dev Anyone can call; balance must be ≥ SWEEP_THRESHOLD
    function sweepFees() external {
        if (feeToken == address(0)) revert FeeTokenNotSet();
        uint256 vaultBalance = IERC20(feeToken).balanceOf(address(this));
        if (vaultBalance == 0 || vaultBalance < SWEEP_THRESHOLD) revert BelowThreshold();
        if (!IERC20(feeToken).transfer(RECIPIENT, vaultBalance)) revert TransferFailed();
        emit FeeSwept(RECIPIENT, vaultBalance);
    }

    /// @notice Query current accumulated fee balance
    function balance() external view returns (uint256) {
        if (feeToken == address(0)) revert FeeTokenNotSet();
        return IERC20(feeToken).balanceOf(address(this));
    }
}
