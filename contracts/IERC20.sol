// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IERC20 - 标准 ERC-20 接口（与 OpenZeppelin IERC20 兼容）
/// @dev 函数签名与 OpenZeppelin IERC20 完全一致，可随时替换为 OZ 依赖。
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
