// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUSDC - Minimal USDC interface (ERC-20 subset)
/// @dev Compatible with USDC on any supported chain
interface IUSDC {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
