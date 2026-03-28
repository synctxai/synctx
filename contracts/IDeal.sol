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

    /// @notice 协议费金额（Trader 读取此值来计算 grossAmount = reward + protocolFee）
    function protocolFee() external view returns (uint96);

    // ===================== 指引与状态 =====================
    // instruction() 是 Agent 理解合约的主要入口。
    // phase() 是平台 UI 的统一状态，dealStatus() 是角色感知的业务状态码。

    /// @notice 返回 Markdown 格式的操作指南
    /// @dev Agent 以此为主要入口理解合约的使用方法
    function instruction() external view returns (string memory);

    /// @notice 平台级统一交易状态
    /// @dev 0=NotFound, 1=Active, 2=Success, 3=Failed, 4=Refunding, 5=Cancelled
    function phase(uint256 dealIndex) external view returns (uint8);

    /// @notice 业务级交易状态码
    /// @dev 由各实现定义，返回角色感知的详细状态码
    function dealStatus(uint256 dealIndex) external view returns (uint8);

    /// @notice 指定索引的交易是否存在
    function dealExists(uint256 dealIndex) external view returns (bool);

    // ===================== 统计 =====================
    // 这些计数器由 DealBase 以 private 存储维护，防止子合约篡改。
    // 平台信誉系统依赖这些数据。

    /// @notice 已创建的交易总数
    function startCount() external view returns (uint256);

    /// @notice 已激活（所有参与方确认）的交易总数
    function activatedCount() external view returns (uint256);

    /// @notice 正常结束的交易总数
    function endCount() external view returns (uint256);

    /// @notice 以争议结束的交易总数
    function disputeCount() external view returns (uint256);

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
    /// @return sig       Verifier owner 的 EIP-712 签名
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
    function onReportResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason) external;

    // ===================== 事件 =====================

    // --- 生命周期事件（统计相关，由 DealBase 内部辅助函数发出） ---

    /// @notice 新交易创建时发出（startCount++）
    event DealCreated(uint256 indexed dealIndex, address[] traders, address[] verifiers);

    /// @notice 所有参与方确认后发出（activatedCount++）
    event DealActivated(uint256 indexed dealIndex);

    /// @notice 交易正常结束时发出（endCount++）
    event DealEnded(uint256 indexed dealIndex);

    /// @notice 交易以争议结束时发出（disputeCount++）
    event DealDisputed(uint256 indexed dealIndex);

    /// @notice 激活前取消时发出（不影响统计计数）
    event DealCancelled(uint256 indexed dealIndex);

    /// @notice 参与方违约时发出
    event DealViolated(uint256 indexed dealIndex, address indexed violator);

    // --- 状态与验证事件 ---

    /// @notice 每次状态转换时发出
    /// @param stateIndex 业务状态枚举值（与角色无关，不同于 dealStatus）
    ///        平台通过 stateIndex + instruction() 推断当前需要谁行动
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
}
