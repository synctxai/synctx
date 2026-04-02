// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SyncTxForwarder - EIP-2771 可信转发器
/// @dev 纯转发器：签名验证 + nonce 防重放 + sender 追加。
///      Gas 费用回收由链下 Relayer 通过 GasSponsorVault 精确扣费。
///      策略控制（合约白名单、用户白名单）由链下 Relayer 负责。
contract SyncTxForwarder {
    error InvalidSignature();
    error ExpiredRequest();
    error NonceMismatch();
    error CallFailed();

    struct ForwardRequest {
        address from;       // 真实 sender
        address to;         // 目标合约
        uint256 nonce;      // from 的当前 nonce
        uint256 deadline;   // 签名有效期 (Unix 秒)
        bytes   data;       // 原始 calldata
    }
    // NOTE: Phase 1 不支持 payable meta-tx（所有 Deal 函数均为 nonpayable），
    // 因此 ForwardRequest 中不包含 value 字段。如果未来需要支持 payable，
    // 需要新增 value 字段并在 execute() 中校验 msg.value。

    /// @dev EIP-2612 Permit 参数（可选，用于免 approve）
    struct PermitData {
        address token;      // ERC20 token 地址（address(0) 表示不需要 permit）
        address spender;    // 被授权方（通常 = req.to，即 Deal 合约）
        uint256 value;      // 授权金额
        uint256 deadline;   // permit 签名有效期
        uint8   v;
        bytes32 r;
        bytes32 s;
    }

    bytes32 private constant _TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,"
        "uint256 nonce,uint256 deadline,bytes data)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address => uint256) public nonces;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,"
                      "uint256 chainId,address verifyingContract)"),
            keccak256("SyncTxForwarder"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    /// @notice 验证签名并转发调用（EIP-2771: calldata 尾部追加 from）
    function execute(ForwardRequest calldata req, bytes calldata sig)
        public returns (bytes memory)
    {
        if (block.timestamp > req.deadline) revert ExpiredRequest();
        if (nonces[req.from] != req.nonce) revert NonceMismatch();

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", DOMAIN_SEPARATOR,
            keccak256(abi.encode(
                _TYPEHASH,
                req.from, req.to,
                req.nonce, req.deadline,
                keccak256(req.data)
            ))
        ));

        (uint8 v, bytes32 r, bytes32 s) = _splitSig(sig);
        address signer = ecrecover(digest, v, r, s);
        if (signer != req.from || signer == address(0)) revert InvalidSignature();

        nonces[req.from] = req.nonce + 1;

        // EIP-2771: calldata = req.data ++ req.from (20 bytes)
        (bool success, bytes memory result) = req.to.call(
            abi.encodePacked(req.data, req.from)
        );
        if (!success) {
            assembly { revert(add(result, 32), mload(result)) }
        }
        return result;
    }

    /// @notice 先执行 EIP-2612 permit（免 approve），再转发调用
    /// @dev permit() 是 permissionless 的——任何人都可以提交有效的 permit 签名，
    ///      不依赖 msg.sender。所以 Forwarder 可以代替用户调用 permit()。
    ///      用户签两份：(1) EIP-2612 Permit 签名，(2) EIP-712 ForwardRequest 签名。
    function executeWithPermit(
        PermitData calldata permit,
        ForwardRequest calldata req,
        bytes calldata sig
    ) external returns (bytes memory) {
        // 1. 执行 permit — 为用户设置 USDC allowance
        if (permit.token != address(0)) {
            IERC20Permit(permit.token).permit(
                req.from,           // owner = 真实用户
                permit.spender,     // spender = Deal 合约
                permit.value,
                permit.deadline,
                permit.v, permit.r, permit.s
            );
        }
        // 2. 转发实际调用
        return this.execute(req, sig);
    }

    /// @notice 批量转发（一次 tx 执行多个 meta-tx，节省 base gas）
    function executeBatch(ForwardRequest[] calldata reqs, bytes[] calldata sigs)
        external
    {
        uint256 len = reqs.length;
        require(len == sigs.length, "length mismatch");
        for (uint256 i = 0; i < len; ) {
            this.execute(reqs[i], sigs[i]);
            unchecked { ++i; }
        }
    }

    function _splitSig(bytes calldata sig)
        private pure returns (uint8 v, bytes32 r, bytes32 s)
    {
        if (sig.length != 65) revert InvalidSignature();
        r = bytes32(sig[0:32]);
        s = bytes32(sig[32:64]);
        v = uint8(bytes1(sig[64:65]));
        if (v < 27) v += 27;
        // EIP-2: reject malleable signatures (high-s)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0)
            revert InvalidSignature();
    }
}

/// @dev 最小 EIP-2612 Permit 接口（仅 Forwarder 内部使用）
interface IERC20Permit {
    function permit(address owner, address spender, uint256 value,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}
