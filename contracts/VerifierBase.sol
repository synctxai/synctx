// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVerifier.sol";
import "./IDeal.sol";
import "./IERC20.sol";
import "./Initializable.sol";

/// @title VerifierBase - 验证者抽象基类
/// @notice 提供通用的验证者功能：owner 管理、DOMAIN_SEPARATOR、结果提交、费用提取。
/// @dev check() 和 EIP-712 验证逻辑在 VerifierSpec 合约中，不在此处。
///      VerifierBase 暴露 DOMAIN_SEPARATOR（public view）和 signer（public）
///      供 Spec 的 check() 读取。DOMAIN_SEPARATOR 支持链分叉时动态重算。
///      角色分离：owner（cold key）管理合约和提取费用，signer（hot key）签名和提交结果。
abstract contract VerifierBase is IVerifier, Initializable {

    // ============ 错误 ============

    error NotOwner();          // 调用者不是 owner
    error NotSigner();         // 调用者不是 signer
    error ZeroAddress();       // 地址为零
    error WithdrawFailed();    // 提取费用失败
    error SignerMustBeEOA();   // signer 必须是 EOA（用于 EIP-712 签名）
    error NoPendingOwner();    // 没有待确认的 pendingOwner
    error FeeNotReceived();    // DealContract 未支付预期的验证费
    error FeeTokenNotSet();    // feeToken 未设置

    // ============ 事件 ============

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SignerChanged(address indexed previousSigner, address indexed newSigner);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ============ 常量 ============
    // EIP-712 域类型哈希，用于构造 DOMAIN_SEPARATOR。

    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // ============ 不可变量 ============

    /// @dev 部署时缓存的 DOMAIN_SEPARATOR 和 chainId，用于动态 fallback
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    /// @dev Verifier 实例名称
    string private _name;

    // ============ 状态 ============

    /// @notice 合约 owner（cold key：管理合约、提取费用）
    address public owner;

    /// @notice 签名者（hot key：签 EIP-712 报价、提交验证结果）
    address public override signer;

    /// @notice Ownable2Step：待确认的新 owner
    address public pendingOwner;

    // ============ 修饰器 ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySigner() {
        if (msg.sender != signer) revert NotSigner();
        _;
    }

    // ============ 构造函数 ============
    // 初始化 owner（部署者）、名称，缓存 EIP-712 DOMAIN_SEPARATOR。
    // DOMAIN_SEPARATOR 在链分叉（chainId 变化）时自动重算。
    // feeToken 通过 setFeeToken() 在部署后一次性设置（跨链统一地址）。

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

    /// @notice 返回当前链的 DOMAIN_SEPARATOR（链分叉时自动重算）
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

    // ============ Owner 管理（Ownable2Step） ============
    // 两步转移：transferOwnership 设置 pendingOwner，acceptOwnership 确认生效。
    // owner 可以是 EOA 或合约（如 multisig），signer 必须是 EOA。

    /// @notice 发起所有权转移（第一步）
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice 接受所有权转移（第二步，由 pendingOwner 调用）
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NoPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    /// @notice 更换签名者（仅 owner）
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        if (newSigner.code.length > 0) revert SignerMustBeEOA();
        address oldSigner = signer;
        signer = newSigner;
        emit SignerChanged(oldSigner, newSigner);
    }

    // ============ IVerifier 实现 ============

    /// @inheritdoc IVerifier
    /// @dev 通过检查 onVerificationResult 调用前后的 feeToken 余额变化来确认 DealContract 已支付验证费。
    ///      如果余额增加量 < expectedFee，交易 revert，验证结果不会被提交。
    ///      这保证了 Verifier 提交结果 = 收到费用，两者原子性完成。
    ///      当 result == 0（inconclusive）时，DealContract 将 fee 退还给请求方/预算，
    ///      Verifier 不会收到费用，因此跳过余额检查。
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

    /// @notice ERC-165 接口检测
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(IVerifier).interfaceId
            || interfaceId == _IERC165_ID;
    }

    // ============ 费用提取 ============
    // owner 可以将累积在合约中的 USDC 验证费提取到指定地址。

    /// @notice 从此合约提取 USDC（仅 owner）
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        if (feeToken == address(0)) revert FeeTokenNotSet();
        if (to == address(0)) revert ZeroAddress();
        if (!IERC20(feeToken).transfer(to, amount)) revert WithdrawFailed();
        emit FeesWithdrawn(to, amount);
    }
}
