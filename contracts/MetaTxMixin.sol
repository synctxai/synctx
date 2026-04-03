// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MetaTxMixin - 嵌入式 meta-transaction 支持
/// @dev 每个合约自己验签、自己记 nonce，不依赖外部 forwarder。
///      继承此 mixin 的合约通过 BySig 函数提供 gasless 入口。
///      constructor 路径传 (name, version)；clone 路径在 initialize() 中调用 _initMetaTxDomain()。
abstract contract MetaTxMixin {

    // ===================== 错误 =====================

    error MetaTxInvalidSignature();
    error MetaTxExpired();
    error MetaTxNonceMismatch();
    error MetaTxUnauthorizedRelayer();
    error PermitFailed();

    // ===================== 类型 =====================

    /// @dev Meta-transaction 签名证明
    struct MetaTxProof {
        address signer;      // 真实用户地址
        address relayer;     // 授权提交者（address(0) = 任意人可提交）
        uint256 nonce;       // signer 在本合约的当前 nonce
        uint256 deadline;    // 签名有效期 (Unix 秒)
        bytes   signature;   // 65 字节 ECDSA 签名
    }

    /// @dev EIP-2612 Permit 参数（spender 固定为 address(this)）
    struct PermitData {
        address token;       // ERC20 token 地址（address(0) = 不需要 permit）
        uint256 value;       // 授权金额
        uint256 deadline;    // permit 有效期
        uint8   v;
        bytes32 r;
        bytes32 s;
    }

    // ===================== EIP-712 =====================

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,"
        "uint256 chainId,address verifyingContract)"
    );

    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;
    bytes32 private _hashedName;
    bytes32 private _hashedVersion;

    // ===================== Nonce =====================

    mapping(address => uint256) public nonces;

    // ===================== 初始化 =====================

    /// @dev Constructor 路径：普通合约直接传 name/version
    constructor(string memory name_, string memory version_) {
        _initMetaTxDomain(name_, version_);
    }

    /// @dev Clone 路径：在 initialize() 中调用
    ///      也可被 constructor 调用（constructor 传参后自动调用）
    function _initMetaTxDomain(string memory name_, string memory version_) internal {
        _hashedName = keccak256(bytes(name_));
        _hashedVersion = keccak256(bytes(version_));
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    // ===================== Domain Separator =====================

    /// @notice 当前链的 EIP-712 domain separator（链分叉时自动重算）
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _cachedChainId && _cachedDomainSeparator != bytes32(0)) {
            return _cachedDomainSeparator;
        }
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            _DOMAIN_TYPEHASH, _hashedName, _hashedVersion,
            block.chainid, address(this)
        ));
    }

    // ===================== 核心验证 =====================

    /// @dev 验证 EIP-712 签名并消耗 nonce。
    ///      ★ nonce 在返回前递增（CEI 模式），后续外部调用无法重入。
    /// @param structHash 业务 typed struct 的 keccak256 哈希
    /// @param proof 用户的 meta-tx 签名证明
    function _verifyMetaTx(bytes32 structHash, MetaTxProof calldata proof) internal {
        // 1. Relayer 绑定（address(0) = 任意人可提交）
        if (proof.relayer != address(0) && msg.sender != proof.relayer)
            revert MetaTxUnauthorizedRelayer();

        // 2. Deadline
        if (block.timestamp > proof.deadline) revert MetaTxExpired();

        // 3. Nonce（CEI：在签名验证和任何外部调用之前消耗）
        if (nonces[proof.signer] != proof.nonce) revert MetaTxNonceMismatch();
        nonces[proof.signer] = proof.nonce + 1;

        // 4. 签名验证
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", DOMAIN_SEPARATOR(), structHash
        ));
        address recovered = _recoverSigner(digest, proof.signature);
        if (recovered != proof.signer || recovered == address(0))
            revert MetaTxInvalidSignature();
    }

    // ===================== Permit 辅助 =====================

    /// @dev 执行 EIP-2612 permit，容忍 front-running（Uniswap V3 标准做法）。
    ///      permit.token == address(0) 时跳过。spender 固定为 address(this)。
    function _executePermit(PermitData calldata permit, address owner) internal {
        if (permit.token == address(0)) return;
        try IERC20Permit(permit.token).permit(
            owner, address(this), permit.value, permit.deadline,
            permit.v, permit.r, permit.s
        ) {} catch {
            if (IERC20Permit(permit.token).allowance(owner, address(this)) < permit.value) {
                revert PermitFailed();
            }
        }
    }

    // ===================== 签名工具 =====================

    function _recoverSigner(bytes32 digest, bytes calldata sig)
        private pure returns (address)
    {
        if (sig.length != 65) revert MetaTxInvalidSignature();

        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(bytes1(sig[64:65]));

        // v 归一化（兼容 0/1 和 27/28 两种格式）
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert MetaTxInvalidSignature();

        // EIP-2: 拒绝 malleable signatures (high-s)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0)
            revert MetaTxInvalidSignature();

        return ecrecover(digest, v, r, s);
    }
}

/// @dev 最小 EIP-2612 Permit 接口
interface IERC20Permit {
    function permit(address owner, address spender, uint256 value,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function allowance(address owner, address spender) external view returns (uint256);
}
