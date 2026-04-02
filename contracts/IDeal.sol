// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDeal - 交易合约标准接口 (v1)
/// @notice 所有交易合约都必须实现此接口，供平台统一识别和管理。
/// @dev 类似于 IERC20 对代币的定义，本接口定义了交易合约的最小标准。
interface IDeal {

    // ===================== 身份标识 =====================
    // 以下函数用于平台搜索、展示和分类合约。

    /// @notice 返回合约名称（如 "XQuoteDealContract"）
    function name() external pure returns (string memory);

    /// @notice 返回合约描述（用于平台搜索展示）
    function description() external pure returns (string memory);

    /// @notice 返回分类标签（如 ["x", "quote"]）
    function tags() external pure returns (string[] memory);

    /// @notice 返回具体合约的实现版本号（如 "1.0.0"）
    function version() external pure returns (string memory);

    /// @notice 返回 IDeal 标准版本号
    function standard() external pure returns (uint8);

    /// @notice ERC-165 接口检测
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);

    /// @notice 协议费收费规则说明
    /// @dev 返回人类可读的收费规则描述，合约自行暴露计算函数供 agent 调用
    function protocolFeePolicy() external view returns (string memory);

    // ===================== 合约生命周期 =====================
    // serviceMode() 是合约级别的营业状态，与 per-deal 的 phase/dealStatus 无关。
    //   0 = TESTING  — 可接受交易，但 admin 保留管理权限（可改参数、可关闭）
    //   1 = OPENING  — 参数冻结，admin 权限永久销毁，不可逆
    //   2 = CLOSED   — 不再接受新交易（已有交易继续执行至完成）

    /// @notice 合约级营业状态
    /// @dev 0=Testing, 1=Opening, 2=Closed
    function serviceMode() external view returns (uint8);

    /// @notice 合约营业状态变更时发出
    event ServiceModeChanged(uint8 indexed mode);

    // ===================== 指引与状态 =====================
    // instruction() 是 Agent 理解合约的主要入口。
    // phase() 是平台 UI 的统一状态，dealStatus() 是角色感知的业务状态码。

    /// @notice 返回 Markdown 格式的操作指南
    /// @dev Agent 以此为主要入口理解合约的使用方法
    function instruction() external view returns (string memory);

    /// @notice 平台级统一交易阶段
    /// @dev 0=NotFound, 1=Pending, 2=Active, 3=Success, 4=Failed, 5=Cancelled
    ///      Pending 表示已创建但未生效（可跳过，直接进入 Active）。
    ///      Cancelled 仅从 Pending 可达；Active 之后只能到 Success 或 Failed。
    function phase(uint256 dealIndex) external view returns (uint8);

    /// @notice 业务级交易状态码
    /// @dev 由各实现定义，返回统一的详细状态码（不依赖 msg.sender）
    function dealStatus(uint256 dealIndex) external view returns (uint8);

    /// @notice 指定索引的交易是否存在
    function dealExists(uint256 dealIndex) external view returns (bool);

    // ===================== 验证 =====================
    // 验证是可选的。不需要验证的合约 requiredSpecs() 返回空数组即可。
    // verificationIndex 是验证槽位的定位标识，一个合约可以有 0 到 N 个验证槽位。

    /// @notice 返回每个验证槽位所需的 VerifierSpec 地址
    /// @dev Trader 选择 Deal 合约后调用此函数，再根据 Spec 地址搜索兼容的 Verifier
    function requiredSpecs() external view returns (address[] memory);

    /// @notice 返回指定验证槽位的完整验证参数
    /// @param dealIndex 交易索引
    /// @param verificationIndex 验证槽位索引
    /// @return verifier  该槽位的 Verifier 合约地址
    /// @return fee       验证费用（USDC 原始值）
    /// @return deadline  签名过期时间（Unix 秒）
    /// @return sig       Verifier signer 的 EIP-712 签名
    /// @return specParams 业务参数（abi.encode 编码，格式由各合约在 instruction() 中文档化）
    function verificationParams(uint256 dealIndex, uint256 verificationIndex)
        external view returns (
            address verifier,
            uint256 fee,
            uint256 deadline,
            bytes memory sig,
            bytes memory specParams
        );

    /// @notice Trader 触发指定验证槽位的验证
    /// @param dealIndex 交易索引
    /// @param verificationIndex 验证槽位索引
    function requestVerification(uint256 dealIndex, uint256 verificationIndex) external;

    /// @notice Verifier 提交验证结果（由 Verifier 合约回调）
    /// @param dealIndex 交易索引
    /// @param verificationIndex 验证槽位索引
    /// @param result 验证结果：正数=通过，负数=失败，0=不确定
    /// @param reason 人类可读的原因描述
    function onVerificationResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason) external;

    // ===================== 事件 =====================

    // --- 子合约事件（工厂模式） ---

    /// @notice 工厂合约创建子合约时发出。平台监听此事件自动发现并注册新的 DealContract。
    /// @dev 仅当合约通过工厂模式生成子合约时需要 emit。子合约必须实现 IDeal 接口。
    ///      平台收到事件后，调用 subContract 的 supportsInterface() 验证，
    ///      再读取 name()/description()/tags() 等元数据完成注册。
    event SubContractCreated(address indexed subContract);

    // --- 生命周期事件（由 DealBase 内部辅助函数发出） ---

    /// @notice 新交易创建时发出（携带参与方信息，供平台建索引）
    event DealCreated(uint256 indexed dealIndex, address[] traders, address[] verifiers);

    /// @notice Phase 变更时发出（合并了 Activated/Ended/Disputed/Cancelled）
    /// @dev 1=Pending, 2=Active, 3=Success, 4=Failed, 5=Cancelled
    ///      DealCreated 已隐含进入 Pending/Active，此事件覆盖后续转换。
    ///      平台按 indexed phase 过滤即可替代原来的多个事件。
    event DealPhaseChanged(uint256 indexed dealIndex, uint8 indexed phase);

    /// @notice 参与方违约时发出（标记违约方与原因，与 DealPhaseChanged→Failed 同时发出）
    event DealViolated(uint256 indexed dealIndex, address indexed violator, string reason);

    // --- 业务状态与验证事件 ---

    /// @notice 每次业务状态转换时发出
    /// @param stateIndex dealStatus 基础值（存储写入时的状态码）
    event DealStateChanged(uint256 indexed dealIndex, uint8 stateIndex);

    /// @notice 收到验证结果时发出
    event VerificationReceived(uint256 indexed dealIndex, uint256 verificationIndex, address indexed verifier, int8 result);

    /// @notice 请求验证时发出
    /// @dev Verifier 监听此事件，然后通过 verificationParams(dealIndex, verificationIndex) 读取完整参数
    event VerificationRequested(
        uint256 indexed dealIndex,
        uint256 verificationIndex,
        address indexed verifier
    );

    /// @notice 协商提案提交时发出
    event SettlementProposed(uint256 indexed dealIndex, address indexed proposer, uint256 amountToA);
}
