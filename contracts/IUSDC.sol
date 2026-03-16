// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUSDC - OP Mainnet USDC interface
/// @dev Address: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85
interface IUSDC {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
