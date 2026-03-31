// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TwitterRegistry - Twitter 身份绑定注册表
/// @notice 存储 EVM 地址与 Twitter user_id 的 1:1 双向绑定。
/// @dev `username` 只作为展示元数据保留，身份 authority 为 `userId`。
///      仅 operator（平台服务端）可写入。验证逻辑在链下完成，合约只存结果。
contract TwitterRegistry {

    // ============ 错误 ============

    error NotOperator();
    error ZeroAddress();
    error InvalidUserId();

    // ============ 事件 ============

    event Bound(address indexed addr, uint64 indexed userId, string username);
    event Unbound(address indexed addr, uint64 indexed userId, string username);

    // ============ 不可变量 ============

    /// @notice 唯一的写入者（平台服务端地址），部署时设定，不可更改
    address public immutable operator;

    // ============ 状态 ============

    /// @notice 地址 → user_id
    mapping(address => uint64) public userIdOf;

    /// @notice 地址 → 用户名（仅 metadata，不作为 authority）
    mapping(address => string) public usernameOf;

    /// @notice user_id → 地址
    mapping(uint64 => address) public addressOfUserId;

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

    /// @notice 绑定地址与 Twitter user_id（自动清除双方旧绑定）
    /// @param addr 要绑定的 EVM 地址
    /// @param userId Twitter/X immutable user_id
    /// @param username 当前用户名（metadata，仅展示用）
    function bind(address addr, uint64 userId, string calldata username) external onlyOperator {
        if (addr == address(0)) revert ZeroAddress();
        if (userId == 0) revert InvalidUserId();

        // 清除该地址的旧绑定
        uint64 oldUserId = userIdOf[addr];
        string memory oldUsername = usernameOf[addr];
        if (oldUserId != 0) {
            delete addressOfUserId[oldUserId];
            emit Unbound(addr, oldUserId, oldUsername);
        }

        // 清除该 user_id 的旧绑定
        address oldAddr = addressOfUserId[userId];
        if (oldAddr != address(0)) {
            uint64 previousUserId = userIdOf[oldAddr];
            string memory previousUsername = usernameOf[oldAddr];
            delete userIdOf[oldAddr];
            delete usernameOf[oldAddr];
            emit Unbound(oldAddr, previousUserId, previousUsername);
        }

        // 写入新绑定
        userIdOf[addr] = userId;
        usernameOf[addr] = username;
        addressOfUserId[userId] = addr;

        emit Bound(addr, userId, username);
    }

    /// @notice 解除地址的绑定
    /// @param addr 要解绑的 EVM 地址
    function unbind(address addr) external onlyOperator {
        uint64 userId = userIdOf[addr];
        string memory username = usernameOf[addr];
        if (userId == 0) return;

        delete userIdOf[addr];
        delete usernameOf[addr];
        delete addressOfUserId[userId];

        emit Unbound(addr, userId, username);
    }

    // ============ 查询 ============

    /// @notice 通过 user_id 查地址
    function getAddressByUserId(uint64 userId) external view returns (address) {
        return addressOfUserId[userId];
    }

    /// @notice 查询完整绑定信息
    function getBinding(address addr) external view returns (uint64 userId, string memory username) {
        return (userIdOf[addr], usernameOf[addr]);
    }
}
