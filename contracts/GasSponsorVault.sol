// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GasSponsorVault - Gas sponsorship pre-funded vault for third-party contracts
/// @dev Admin registers a contract's funder (prevents squatting), funder deposits/withdraws ETH,
///      Relayer calculates exact gas off-chain then batch-deducts fees.
///      Funds are completely isolated from Deal escrow — Vault is an independent contract with its own ETH balance.
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

    /// @dev Contract address => remaining ETH budget (wei)
    mapping(address => uint256) public budgets;
    /// @dev Contract address => funder address (registered by admin, authorized to deposit/withdraw)
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

    // ── Admin Operations ──

    /// @notice Admin registers/changes a contract's funder
    /// @dev Can be called multiple times to change funder; after change, the old funder loses deposit/withdraw rights
    function registerFunder(address dealContract, address funder) external onlyAdmin {
        if (dealContract == address(0) || funder == address(0)) revert ZeroAddress();
        funderOf[dealContract] = funder;
        emit FunderRegistered(dealContract, funder);
    }

    /// @notice Admin transfers admin rights
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // ── Funder Operations ──

    /// @notice Deposit ETH gas sponsorship budget for a specific contract (must be registered by admin first)
    function fund(address dealContract) external payable nonReentrant {
        if (dealContract == address(0)) revert ZeroAddress();
        address f = funderOf[dealContract];
        if (f == address(0)) revert NotRegistered();
        if (msg.sender != f) revert OnlyFunder();
        budgets[dealContract] += msg.value;
        emit Funded(dealContract, msg.sender, msg.value);
    }

    /// @notice Funder withdraws remaining budget
    function withdraw(address dealContract, uint256 amount) external nonReentrant {
        if (msg.sender != funderOf[dealContract]) revert OnlyFunder();
        if (budgets[dealContract] < amount) revert InsufficientBudget();
        budgets[dealContract] -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(dealContract, msg.sender, amount);
    }

    // ── Relayer Operations ──

    /// @notice Relayer batch-deducts fees (accumulate receipts then submit in one call)
    /// @param contracts Target contract address array
    /// @param costs Corresponding exact gas cost array (wei)
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

    /// @notice Relayer single deduction
    function deduct(address dealContract, uint256 gasCost) external nonReentrant {
        if (msg.sender != RELAYER) revert OnlyRelayer();
        if (budgets[dealContract] < gasCost) revert InsufficientBudget();
        budgets[dealContract] -= gasCost;
        (bool ok, ) = TREASURY.call{value: gasCost}("");
        if (!ok) revert TransferFailed();
        emit Deducted(dealContract, gasCost);
    }

    // ── View ──

    /// @notice Query a contract's remaining ETH budget
    function budget(address dealContract) external view returns (uint256) {
        return budgets[dealContract];
    }
}
