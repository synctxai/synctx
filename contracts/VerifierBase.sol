// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVerifier.sol";
import "./IDeal.sol";
import "./IERC20.sol";
import "./Initializable.sol";

/// @title VerifierBase - 验证者抽象基类
/// @notice 提供通用的验证者功能：owner 管理、DOMAIN_SEPARATOR、结果提交、费用提取。
/// @dev check() 和 EIP-712 验证逻辑在 VerifierSpec 合约中，不在此处。
///      VerifierBase 暴露 DOMAIN_SEPARATOR（public immutable）和 owner（public）
///      供 Spec 的 check() 读取。
abstract contract VerifierBase is IVerifier, Initializable {

    // ============ 错误 ============

    error NotOwner();          // 调用者不是 owner
    error ZeroAddress();       // 地址为零
    error WithdrawFailed();    // 提取费用失败
    error NewOwnerIsContract();// 新 owner 不能是合约地址（必须是 EOA）
    error FeeNotReceived();    // DealContract 未支付预期的验证费

    // ============ 事件 ============

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ============ 常量 ============
    // EIP-712 域类型哈希，用于构造 DOMAIN_SEPARATOR。

    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // ============ 不可变量 ============

    /// @notice EIP-712 域分隔符（由 name + version + chainId + address 在构造时计算）
    bytes32 public immutable override DOMAIN_SEPARATOR;

    /// @dev Verifier 实例名称
    string private _name;

    // ============ 状态 ============

    /// @notice 合约 owner（签名和调用 reportResult 的 EOA）
    address public override owner;

    // ============ 修饰器 ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ============ 构造函数 ============
    // 初始化 owner（部署者）、名称，并计算 EIP-712 DOMAIN_SEPARATOR。
    // feeToken 通过 setFeeToken() 在部署后一次性设置（跨链统一地址）。

    constructor(string memory name_, string memory version_) {
        _setInitializer();
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

    // ============ Owner 管理 ============
    // 只有当前 owner 可以转移所有权。新 owner 必须是 EOA（不能是合约）。

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner.code.length > 0) revert NewOwnerIsContract();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ============ IVerifier 实现 ============

    /// @inheritdoc IVerifier
    /// @dev 通过检查 onVerificationResult 调用前后的 USDC 余额变化来确认 DealContract 已支付验证费。
    ///      如果余额增加量 < expectedFee，交易 revert，验证结果不会被提交。
    ///      这保证了 Verifier 提交结果 = 收到费用，两者原子性完成。
    function reportResult(
        address dealContract,
        uint256 dealIndex,
        uint256 verificationIndex,
        int8 result,
        string calldata reason,
        uint256 expectedFee
    ) external override onlyOwner {
        uint256 balBefore = IERC20(feeToken).balanceOf(address(this));
        IDeal(dealContract).onVerificationResult(dealIndex, verificationIndex, result, reason);
        if (IERC20(feeToken).balanceOf(address(this)) - balBefore < expectedFee) revert FeeNotReceived();
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
        if (to == address(0)) revert ZeroAddress();
        if (!IERC20(feeToken).transfer(to, amount)) revert WithdrawFailed();
    }
}
