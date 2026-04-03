// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Initializable - One-time initialization support
/// @notice Cross-chain unified address deployment: chain-specific params (feeToken) are set once by the deployer after deployment.
/// @dev The deployer (msg.sender of the constructor) is the sole initializer.
///      After setFeeToken is called, the initializer is cleared and no longer holds any privileges.
abstract contract Initializable {
    error AlreadyInitialized();
    error NotInitializer();
    error FeeTokenInvalid();

    event FeeTokenSet(address indexed feeToken);

    /// @dev Deployer address, cleared after setFeeToken is called
    address private _initializer;

    /// @notice Fee token address (e.g. USDC)
    address public feeToken;

    /// @dev Called in subcontract constructor to record the deployer as initializer
    function _setInitializer() internal {
        _initializer = msg.sender;
    }

    modifier onlyInitializer() {
        if (_initializer == address(0)) revert AlreadyInitialized();
        if (msg.sender != _initializer) revert NotInitializer();
        _;
        _initializer = address(0);
    }

    /// @notice Set the fee token address (one-time, deployer only)
    function setFeeToken(address feeToken_) external onlyInitializer {
        if (feeToken_ == address(0) || feeToken_.code.length == 0) revert FeeTokenInvalid();
        feeToken = feeToken_;
        emit FeeTokenSet(feeToken_);
    }
}
