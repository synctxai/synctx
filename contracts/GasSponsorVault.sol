// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GasSponsorVault - 第三方合约的 gas 赞助预充值金库
/// @dev Admin 注册合约的 funder（防抢注），funder 自行充值/提取 ETH，
///      Relayer 链下计算精确 gas 后批量扣费。
///      资金与 Deal 托管资金完全隔离——Vault 是独立合约，持有独立 ETH 余额。
contract GasSponsorVault {
    error InsufficientBudget();
    error OnlyRelayer();
    error OnlyFunder();
    error OnlyAdmin();
    error ZeroAddress();
    error TransferFailed();
    error LengthMismatch();
    error NotRegistered();
    error ReentrancyGuard();

    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event FunderRegistered(address indexed dealContract, address indexed funder);
    event Funded(address indexed dealContract, address indexed funder, uint256 amount);
    event Withdrawn(address indexed dealContract, address indexed funder, uint256 amount);
    event Deducted(address indexed dealContract, uint256 gasCost);
    event BatchDeducted(uint256 totalCost, uint256 count);

    address public immutable RELAYER;
    address payable public immutable TREASURY;
    address public admin;

    uint256 private _lock = 1;
    modifier nonReentrant() {
        if (_lock != 1) revert ReentrancyGuard();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @dev 合约地址 => 剩余 ETH 预算 (wei)
    mapping(address => uint256) public budgets;
    /// @dev 合约地址 => funder 地址（admin 注册，有权充值/withdraw）
    mapping(address => address) public funderOf;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor(address relayer, address payable treasury, address admin_) {
        if (relayer == address(0) || treasury == address(0) || admin_ == address(0))
            revert ZeroAddress();
        RELAYER = relayer;
        TREASURY = treasury;
        admin = admin_;
    }

    // ── Admin 操作 ──

    /// @notice Admin 注册/变更合约的 funder
    /// @dev 可重复调用以变更 funder；变更后旧 funder 失去充值/提取权
    function registerFunder(address dealContract, address funder) external onlyAdmin {
        if (dealContract == address(0) || funder == address(0)) revert ZeroAddress();
        funderOf[dealContract] = funder;
        emit FunderRegistered(dealContract, funder);
    }

    /// @notice Admin 转让管理权
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // ── Funder 操作 ──

    /// @notice 为指定合约充值 ETH gas 赞助预算（必须先由 admin 注册）
    function fund(address dealContract) external payable nonReentrant {
        if (dealContract == address(0)) revert ZeroAddress();
        address f = funderOf[dealContract];
        if (f == address(0)) revert NotRegistered();
        if (msg.sender != f) revert OnlyFunder();
        budgets[dealContract] += msg.value;
        emit Funded(dealContract, msg.sender, msg.value);
    }

    /// @notice Funder 提取剩余预算
    function withdraw(address dealContract, uint256 amount) external nonReentrant {
        if (msg.sender != funderOf[dealContract]) revert OnlyFunder();
        if (budgets[dealContract] < amount) revert InsufficientBudget();
        budgets[dealContract] -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(dealContract, msg.sender, amount);
    }

    // ── Relayer 操作 ──

    /// @notice Relayer 批量扣费（攒一批 receipt 后一次性提交）
    /// @param contracts 目标合约地址数组
    /// @param costs 对应的精确 gas 费用数组 (wei)
    function deductBatch(
        address[] calldata contracts,
        uint256[] calldata costs
    ) external nonReentrant {
        if (msg.sender != RELAYER) revert OnlyRelayer();
        if (contracts.length != costs.length) revert LengthMismatch();

        uint256 total;
        for (uint256 i = 0; i < contracts.length; ) {
            uint256 cost = costs[i];
            address c = contracts[i];
            if (budgets[c] < cost) revert InsufficientBudget();
            budgets[c] -= cost;
            total += cost;
            emit Deducted(c, cost);
            unchecked { ++i; }
        }

        if (total > 0) {
            (bool ok, ) = TREASURY.call{value: total}("");
            if (!ok) revert TransferFailed();
        }
        emit BatchDeducted(total, contracts.length);
    }

    /// @notice Relayer 单笔扣费
    function deduct(address dealContract, uint256 gasCost) external nonReentrant {
        if (msg.sender != RELAYER) revert OnlyRelayer();
        if (budgets[dealContract] < gasCost) revert InsufficientBudget();
        budgets[dealContract] -= gasCost;
        (bool ok, ) = TREASURY.call{value: gasCost}("");
        if (!ok) revert TransferFailed();
        emit Deducted(dealContract, gasCost);
    }

    // ── View ──

    /// @notice 查询合约的剩余 ETH 预算
    function budget(address dealContract) external view returns (uint256) {
        return budgets[dealContract];
    }
}
