// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TwitterRegistry - Twitter 身份绑定注册表
/// @notice 存储 EVM 地址与 Twitter 用户名的 1:1 双向绑定。
/// @dev 仅 operator（平台服务端）可写入。验证逻辑在链下完成，合约只存结果。
contract TwitterRegistry {

    // ============ 错误 ============

    error NotOperator();
    error ZeroAddress();
    error EmptyUsername();

    // ============ 事件 ============

    event Bound(address indexed addr, string username);
    event Unbound(address indexed addr, string username);

    // ============ 不可变量 ============

    /// @notice 唯一的写入者（平台服务端地址），部署时设定，不可更改
    address public immutable operator;

    // ============ 状态 ============

    /// @notice 地址 → 用户名
    mapping(address => string) public usernameOf;

    /// @notice keccak256(lowercase username) → 地址
    mapping(bytes32 => address) public addressOf;

    // ============ 修饰器 ============

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // ============ 构造函数 ============

    constructor(address operator_) {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
    }

    // ============ 写入 ============

    /// @notice 绑定地址与 Twitter 用户名（自动清除双方旧绑定）
    /// @param addr 要绑定的 EVM 地址
    /// @param username Twitter 用户名（小写，不含 @）
    function bind(address addr, string calldata username) external onlyOperator {
        if (addr == address(0)) revert ZeroAddress();
        if (bytes(username).length == 0) revert EmptyUsername();

        bytes32 usernameHash = keccak256(bytes(username));

        // 清除该地址的旧绑定
        string memory oldUsername = usernameOf[addr];
        if (bytes(oldUsername).length > 0) {
            bytes32 oldHash = keccak256(bytes(oldUsername));
            delete addressOf[oldHash];
            emit Unbound(addr, oldUsername);
        }

        // 清除该用户名的旧绑定
        address oldAddr = addressOf[usernameHash];
        if (oldAddr != address(0)) {
            delete usernameOf[oldAddr];
            emit Unbound(oldAddr, username);
        }

        // 写入新绑定
        usernameOf[addr] = username;
        addressOf[usernameHash] = addr;

        emit Bound(addr, username);
    }

    /// @notice 解除地址的绑定
    /// @param addr 要解绑的 EVM 地址
    function unbind(address addr) external onlyOperator {
        string memory username = usernameOf[addr];
        if (bytes(username).length == 0) return;

        bytes32 usernameHash = keccak256(bytes(username));
        delete usernameOf[addr];
        delete addressOf[usernameHash];

        emit Unbound(addr, username);
    }

    // ============ 查询 ============

    /// @notice 通过用户名查地址
    /// @param username Twitter 用户名（小写，不含 @）
    function getAddressByUsername(string calldata username) external view returns (address) {
        return addressOf[keccak256(bytes(username))];
    }
}
