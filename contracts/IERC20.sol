// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IERC20 - Standard ERC-20 interface (OpenZeppelin IERC20 compatible)
/// @dev Function signatures are identical to OpenZeppelin IERC20; can be swapped for the OZ dependency at any time.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
