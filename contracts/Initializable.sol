// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Initializable - 一次性初始化支持
/// @notice 跨链统一地址部署：链特定参数（feeToken）在部署后由 deployer 一次性设置。
/// @dev deployer（constructor 的 msg.sender）为唯一 initializer。
///      setFeeToken 调用后 initializer 自动清零，不再拥有任何权限。
abstract contract Initializable {
    error AlreadyInitialized();
    error NotInitializer();
    error FeeTokenInvalid();

    event FeeTokenSet(address indexed feeToken);

    /// @dev 部署者地址，setFeeToken 调用后清零
    address private _initializer;

    /// @notice 费用代币地址（如 USDC）
    address public feeToken;

    /// @dev 子合约 constructor 中调用，记录部署者为 initializer
    function _setInitializer() internal {
        _initializer = msg.sender;
    }

    modifier onlyInitializer() {
        if (_initializer == address(0)) revert AlreadyInitialized();
        if (msg.sender != _initializer) revert NotInitializer();
        _;
        _initializer = address(0);
    }

    /// @notice 设置费用代币地址（一次性，仅 deployer 可调用）
    function setFeeToken(address feeToken_) external onlyInitializer {
        if (feeToken_ == address(0) || feeToken_.code.length == 0) revert FeeTokenInvalid();
        feeToken = feeToken_;
        emit FeeTokenSet(feeToken_);
    }
}
