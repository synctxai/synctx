// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GasSponsorVault - 第三方合约的 gas 赞助预充值金库
/// @dev 开发者为自己的合约充值 ETH，Relayer 链下计算精确 gas 后批量扣费。
///      资金与 Deal 托管资金完全隔离——Vault 是独立合约，持有独立 ETH 余额。
contract GasSponsorVault {
    error InsufficientBudget();
    error OnlyRelayer();
    error ZeroAddress();
    error TransferFailed();
    error LengthMismatch();

    event Funded(address indexed dealContract, address indexed funder, uint256 amount);
    event Deducted(address indexed dealContract, uint256 gasCost);
    event BatchDeducted(uint256 totalCost, uint256 count);

    address public immutable RELAYER;
    address payable public immutable TREASURY;

    /// @dev 合约地址 => 剩余 ETH 预算 (wei)
    mapping(address => uint256) public budgets;

    constructor(address relayer, address payable treasury) {
        if (relayer == address(0) || treasury == address(0))
            revert ZeroAddress();
        RELAYER = relayer;
        TREASURY = treasury;
    }

    /// @notice 为指定合约充值 ETH gas 赞助预算
    /// @dev 任何人都可以为任何合约充值（开发者、投资人、用户均可）
    function fund(address dealContract) external payable {
        budgets[dealContract] += msg.value;
        emit Funded(dealContract, msg.sender, msg.value);
    }

    /// @notice Relayer 批量扣费（攒一批 receipt 后一次性提交）
    /// @param contracts 目标合约地址数组
    /// @param costs 对应的精确 gas 费用数组 (wei)
    function deductBatch(
        address[] calldata contracts,
        uint256[] calldata costs
    ) external {
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
    function deduct(address dealContract, uint256 gasCost) external {
        if (msg.sender != RELAYER) revert OnlyRelayer();
        if (budgets[dealContract] < gasCost) revert InsufficientBudget();
        budgets[dealContract] -= gasCost;
        (bool ok, ) = TREASURY.call{value: gasCost}("");
        if (!ok) revert TransferFailed();
        emit Deducted(dealContract, gasCost);
    }

    /// @notice 查询合约的剩余 ETH 预算
    function budget(address dealContract) external view returns (uint256) {
        return budgets[dealContract];
    }
}
