// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVerifier.sol";
import "./IDeal.sol";
import "./IERC20.sol";
import "./Initializable.sol";

/// @title VerifierBase - Abstract base class for verifiers
/// @notice Provides common verifier functionality: owner management, DOMAIN_SEPARATOR, result submission, fee withdrawal.
/// @dev check() and EIP-712 verification logic are in VerifierSpec contracts, not here.
///      VerifierBase exposes DOMAIN_SEPARATOR (public view) and signer (public)
///      for Spec's check() to read. DOMAIN_SEPARATOR supports dynamic recomputation on chain forks.
///      Role separation: owner (cold key) manages contract and withdraws fees, signer (hot key) signs and submits results.
abstract contract VerifierBase is IVerifier, Initializable {

    // ============ Errors ============

    error NotOwner();          // Caller is not the owner
    error NotSigner();         // Caller is not the signer
    error ZeroAddress();       // Address is zero
    error WithdrawFailed();    // Fee withdrawal failed
    error SignerMustBeEOA();   // Signer must be an EOA (for EIP-712 signing)
    error NoPendingOwner();    // No pending owner to confirm
    error FeeNotReceived();    // DealContract did not pay the expected verification fee
    error FeeTokenNotSet();    // feeToken not set

    // ============ Events ============

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SignerChanged(address indexed previousSigner, address indexed newSigner);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ============ Constants ============
    // EIP-712 domain type hash, used to construct DOMAIN_SEPARATOR.

    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // ============ Immutables ============

    /// @dev Cached DOMAIN_SEPARATOR and chainId at deployment, used for dynamic fallback
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    /// @dev Verifier instance name
    string private _name;

    // ============ State ============

    /// @notice Contract owner (cold key: manages contract, withdraws fees)
    address public owner;

    /// @notice Signer (hot key: signs EIP-712 quotes, submits verification results)
    address public override signer;

    /// @notice Ownable2Step: pending new owner
    address public pendingOwner;

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySigner() {
        if (msg.sender != signer) revert NotSigner();
        _;
    }

    // ============ Constructor ============
    // Initializes owner (deployer), name, and caches EIP-712 DOMAIN_SEPARATOR.
    // DOMAIN_SEPARATOR is automatically recomputed on chain forks (chainId change).
    // feeToken is set via setFeeToken() after deployment (cross-chain unified address).

    constructor(string memory name_, string memory version_) {
        _setInitializer();
        owner = msg.sender;
        signer = msg.sender;
        _name = name_;
        _HASHED_NAME = keccak256(bytes(name_));
        _HASHED_VERSION = keccak256(bytes(version_));
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice Returns current chain's DOMAIN_SEPARATOR (auto-recomputed on chain fork)
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID
            ? _CACHED_DOMAIN_SEPARATOR
            : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION,
            block.chainid, address(this)
        ));
    }

    // ============ Owner Management (Ownable2Step) ============
    // Two-step transfer: transferOwnership sets pendingOwner, acceptOwnership confirms.
    // Owner can be an EOA or contract (e.g. multisig); signer must be an EOA.

    /// @notice Initiate ownership transfer (step 1)
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership transfer (step 2, called by pendingOwner)
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NoPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    /// @notice Change the signer (owner only)
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        if (newSigner.code.length > 0) revert SignerMustBeEOA();
        address oldSigner = signer;
        signer = newSigner;
        emit SignerChanged(oldSigner, newSigner);
    }

    // ============ IVerifier Implementation ============

    /// @inheritdoc IVerifier
    /// @dev Checks feeToken balance before/after onVerificationResult to confirm DealContract paid the verification fee.
    ///      If balance increase < expectedFee, the tx reverts and the result is NOT submitted.
    ///      This guarantees that submitting result = receiving fee, atomically.
    ///      When result == 0 (inconclusive), DealContract refunds the fee to the requester/budget,
    ///      so the Verifier does not receive a fee — balance check is skipped.
    function reportResult(
        address dealContract,
        uint256 dealIndex,
        uint256 verificationIndex,
        int8 result,
        string calldata reason,
        uint256 expectedFee
    ) external override onlySigner {
        if (feeToken == address(0)) revert FeeTokenNotSet();
        uint256 balBefore = IERC20(feeToken).balanceOf(address(this));
        IDeal(dealContract).onVerificationResult(dealIndex, verificationIndex, result, reason);
        // Conclusive results (>0, <0): verifier receives fee — enforce balance check.
        // Inconclusive (==0): fee refunded to requester/budget by design — skip check.
        if (result != 0 && IERC20(feeToken).balanceOf(address(this)) - balBefore < expectedFee) revert FeeNotReceived();
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
    // Owner can withdraw accumulated USDC verification fees from the contract to a specified address.

    /// @notice Withdraw fees from this contract (owner only)
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        if (feeToken == address(0)) revert FeeTokenNotSet();
        if (to == address(0)) revert ZeroAddress();
        if (!IERC20(feeToken).transfer(to, amount)) revert WithdrawFailed();
        emit FeesWithdrawn(to, amount);
    }
}
