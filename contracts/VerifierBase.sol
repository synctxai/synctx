// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVerifier.sol";
import "./IDealContract.sol";

/// @title VerifierBase - Abstract base class for verifiers
/// @notice Provides common verifier functionality: owner management, DOMAIN_SEPARATOR, result submission, fee withdrawal.
/// @dev check() and EIP-712 verification logic are in VerifierSpec contracts, not here.
///      VerifierBase exposes DOMAIN_SEPARATOR (public immutable) and owner (public) for Spec's check() to read.
abstract contract VerifierBase is IVerifier {

    // ============ Errors ============

    error NotOwner();
    error ZeroAddress();
    error WithdrawFailed();
    error NewOwnerIsContract();
    error FeeNotReceived();

    // ============ Events ============

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ============ Constants ============

    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // ============ Immutables ============

    /// @notice USDC token address (set by subclass via constructor)
    address public immutable USDC;
    bytes32 public immutable override DOMAIN_SEPARATOR;
    string private _name;

    // ============ State ============

    address public override owner;

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ============ Constructor ============

    constructor(address usdc_, string memory name_, string memory version_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        USDC = usdc_;
        owner = msg.sender;
        _name = name_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name_)),
                keccak256(bytes(version_)),
                block.chainid,
                address(this)
            )
        );
    }

    // ============ Owner Management ============

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner.code.length > 0) revert NewOwnerIsContract();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ============ IVerifier Implementation ============

    /// @inheritdoc IVerifier
    /// @dev Checks USDC balance before/after onReportResult to ensure DealContract paid the exact escrowed fee.
    ///      If balance increase < expectedFee, the tx reverts and result is NOT submitted.
    function reportResult(
        address dealContract,
        uint256 dealIndex,
        uint256 verificationIndex,
        int8 result,
        string calldata reason,
        uint256 expectedFee
    ) external override onlyOwner {
        uint256 balBefore = IVerifierUSDC(USDC).balanceOf(address(this));
        IDealContract(dealContract).onReportResult(dealIndex, verificationIndex, result, reason);
        if (IVerifierUSDC(USDC).balanceOf(address(this)) - balBefore < expectedFee) revert FeeNotReceived();
    }

    /// @inheritdoc IVerifier
    function name() external view virtual override returns (string memory) {
        return _name;
    }

    /// @inheritdoc IVerifier
    function description() external view virtual override returns (string memory);

    /// @inheritdoc IVerifier
    function spec() external view virtual override returns (address);

    /// @dev IERC165 interfaceId = bytes4(keccak256("supportsInterface(bytes4)"))
    bytes4 private constant _IERC165_ID = 0x01ffc9a7;

    /// @notice ERC-165 interface detection
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(IVerifier).interfaceId
            || interfaceId == _IERC165_ID;
    }

    // ============ Fee Withdrawal ============

    /// @notice Withdraw USDC from this contract (only owner)
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (!IVerifierUSDC(USDC).transfer(to, amount)) revert WithdrawFailed();
    }
}

/// @dev Minimal USDC interface for fee withdrawal and balance check
interface IVerifierUSDC {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
