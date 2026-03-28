// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealBase.sol";
import "./IVerifier.sol";
import "./IVerifierSpec.sol";
import "./XQuoteVerifierSpec.sol";
import "./IERC20.sol";


/// @title XQuoteDealContract - X 引用推文交易合约
/// @notice 单合约管理所有交易。USDC 地址通过构造函数设置。
/// @dev USDC approve · 紧凑存储 · 自定义错误 · 直接支付
///      v4：VerifierSpec 架构 — 通过 Spec 合约执行 check()，扁平化验证参数
///
///      交易流程概览：
///      1. A 创建交易，存入 USDC（reward + protocolFee），指定 B 和 Verifier
///      2. B 接受交易（protocolFee 此时支付给 FeeCollector）
///      3. B 在 X 上引用推文，然后调用 claimDone 提交 quote_tweet_id
///      4. A 手动确认付款，或请求 Verifier 自动验证
///      5. 如果验证不确定或 Verifier 超时，进入协商阶段
contract XQuoteDealContract is DealBase {

    // ===================== 错误 =====================
    // 使用 custom errors 代替 require(message)，更省 gas 且调试友好。

    error NotPartyA();              // 调用者不是 A 方
    error NotPartyB();              // 调用者不是 B 方
    error NotVerifier();            // 调用者不是指定的 Verifier
    error NotAorB();                // 调用者既不是 A 也不是 B
    error InvalidState();           // 当前状态不允许此操作
    error NotTimedOut();            // 尚未超时
    error AlreadyTimedOut();        // 已经超时
    error AlreadyRequested();       // 验证已请求过
    error NotRequested();           // 验证未被请求
    error NoFunds();                // 无可提取的资金
    error InvalidParams();          // 参数无效
    error TransferFailed();         // USDC 转账失败
    error ViolatorCannot();         // 违约方不能执行此操作
    error VerificationPending();    // 验证进行中，不能执行此操作
    error VerificationNotTimedOut();// 验证尚未超时
    error ProposerCannotConfirm();  // 提案方不能确认自己的提案
    error InvalidSettlement();      // 无效的协商提案
    error SettlementNotTimedOut();  // 协商尚未超时
    error FeeTooLow();              // 协议费低于最低值
    error InvalidFeeCollector();    // FeeCollector 地址无效
    error VerifierNotContract();    // Verifier 地址不是合约
    error InvalidVerifierSignature();    // Verifier 签名无效
    error SignatureExpired();       // 签名已过期
    error InvalidVerificationIndex();// 验证槽位索引无效
    error InvalidSpecAddress();     // Spec 地址不匹配
    error InsufficientAllowance();  // USDC 授权额度不足
    error InsufficientBalance();    // USDC 余额不足

    // ===================== 类型 =====================

    /// @dev 交易状态枚举 — 定义了完整的状态机
    enum State {
        Created,     // 0 - A 已创建并存款，等待 B 接受
        Accepted,    // 1 - B 已接受，等待 B 引用推文并 claimDone
        ClaimedDone, // 2 - B 声称已完成，等待 A 确认
        Completed,   // 3 - 完成，资金已发送给 B
        Violated,    // 4 - 以违约终止
        Settling,    // 5 - Verifier 不确定/超时，A/B 正在协商
        Cancelled    // 6 - B 未接受，A 已撤回资金
    }

    /// @dev 紧凑存储到最少的存储槽。
    ///      单验证槽位特化（requiredSpecs().length == 1）。
    ///      验证字段对应唯一的验证槽位 verificationIndex == 0。
    struct Deal {
        // 槽 1（30/32 字节）
        address partyA;                   // 20 字节 — A 方地址（发起者/付款方）
        uint48  stageTimestamp;           // 6 字节  — 当前阶段开始时间
        uint8   state;                    // 1 字节  — 当前状态
        bool    verificationRequested;    // 1 字节  — 是否已请求验证
        bool    isRequesterA;             // 1 字节  — 验证请求方是否为 A（用于超时退费）
        // 槽 2
        address partyB;                   // 20 字节 — B 方地址（执行者/引用者）
        uint96  amount;                   // 12 字节 — 托管金额（grossAmount - protocolFee）
        // 槽 3 — Verifier 信息（槽位 0）
        address verifier;                 // 20 字节 — Verifier 合约地址
        uint96  verifierFee;              // 12 字节 — 验证费用
        // 槽 4（26/32 字节 — violator 和 verificationTimestamp 互斥使用）
        address violator;                 // 20 字节 — 违约方地址
        uint48  verificationTimestamp;    // 6 字节  — 验证请求的时间戳
        // 槽 5 — 签名截止时间（槽位 0）
        uint256 signatureDeadline;
        // 动态类型（各占独立的存储槽）
        string  tweet_id;                 // 要被引用的推文 ID
        string  quoter_username;         // 规范化后的用户名：无前导 @，全小写
        string  quote_tweet_id;           // B 的引用推文 ID，由 claimDone 设置
        bytes   verifierSignature;        // EIP-712 签名（槽位 0，65 字节）
    }

    /// @dev 协商提案，仅在 Settling 状态使用
    struct Settlement {
        address proposer;     // 20 字节 — 提案方
        uint96  amountToA;    // 12 字节 — 提议给 A 的金额（剩余归 B）
    }

    // ===================== 常量 =====================

    /// @notice 最低协议费（0.01 USDC，6 位小数）
    uint96 public constant MIN_PROTOCOL_FEE = 10_000;

    /// @notice 每个阶段的超时时间
    uint256 public constant STAGE_TIMEOUT = 30 minutes;

    /// @notice Verifier 在验证请求后的响应超时
    uint256 public constant VERIFICATION_TIMEOUT = 30 minutes;

    /// @notice A/B 在协商超时前必须达成一致，否则资金被没收
    uint256 public constant SETTLING_TIMEOUT = 12 hours;

    /// @notice USDC 代币地址
    address public immutable USDC;

    /// @notice 协议费收集器合约
    address public immutable FEE_COLLECTOR;

    /// @notice 协议费 — 激活后支付，取消时全额退还
    uint96 public immutable PROTOCOL_FEE;

    /// @notice 验证槽位 0 所需的 VerifierSpec 地址
    address public immutable REQUIRED_SPEC;

    // ===================== 存储 =====================

    /// @notice 所有交易，按索引存储
    mapping(uint256 => Deal) internal deals;

    /// @notice 协商提案（仅在 Settling 状态使用）
    mapping(uint256 => Settlement) internal settlements;

    // ===================== 业务事件 =====================
    // 这些事件是 XQuote 特有的，补充 IDeal 标准事件。

    event DealAccepted(uint256 indexed dealIndex);
    event DealClaimedDone(uint256 indexed dealIndex);
    event DealCompleted(uint256 indexed dealIndex, uint256 amount);
    event Withdrawn(uint256 indexed dealIndex, address indexed recipient, uint96 amount);
    event VerificationReset(uint256 indexed dealIndex, uint256 verificationIndex, address indexed verifier);
    event SettlingStarted(uint256 indexed dealIndex);
    event SettlementProposed(uint256 indexed dealIndex, address indexed proposer, uint96 amountToA);
    event SettlementConfirmed(uint256 indexed dealIndex);
    event SettlementTimedOutSeized(uint256 indexed dealIndex, uint96 amountSeized);
    event ProtocolFeePaid(uint256 indexed dealIndex, uint96 fee);
    event FundsSeized(uint256 indexed dealIndex, uint96 amount);
    event DealFeeSplit(uint256 indexed dealIndex, uint96 grossAmount, uint96 fee, uint96 netAmount);

    // ===================== 修饰器 =====================
    // 权限和状态检查的复用模式。

    modifier onlyA(uint256 dealIndex) {
        if (msg.sender != deals[dealIndex].partyA) revert NotPartyA();
        _;
    }

    modifier onlyB(uint256 dealIndex) {
        if (msg.sender != deals[dealIndex].partyB) revert NotPartyB();
        _;
    }

    modifier inState(uint256 dealIndex, State s) {
        if (deals[dealIndex].state != uint8(s)) revert InvalidState();
        _;
    }

    modifier notTimedOut(uint256 dealIndex) {
        if (_isTimedOut(dealIndex)) revert AlreadyTimedOut();
        _;
    }

    /// @dev 此合约恰好有 1 个验证槽位（索引 0）
    modifier onlySlot0(uint256 verificationIndex) {
        if (verificationIndex != 0) revert InvalidVerificationIndex();
        _;
    }

    // ===================== 构造函数 =====================
    // 所有关键地址和参数在部署时设定为 immutable，不可更改。

    constructor(address usdc_, address feeCollector, uint96 protocolFee_, address requiredSpec) {
        if (usdc_ == address(0)) revert InvalidParams();
        if (feeCollector == address(0) || feeCollector == address(this) || feeCollector.code.length == 0) {
            revert InvalidFeeCollector();
        }
        if (protocolFee_ < MIN_PROTOCOL_FEE) revert FeeTooLow();
        if (requiredSpec == address(0)) revert InvalidSpecAddress();
        USDC = usdc_;
        FEE_COLLECTOR = feeCollector;
        PROTOCOL_FEE = protocolFee_;
        REQUIRED_SPEC = requiredSpec;
    }

    // ===================== 创建交易 =====================

    /// @notice 创建交易（需要预先 approve USDC）
    /// @dev 流程：参数校验 → Verifier 签名验证 → USDC 转入托管 → 记录交易数据
    /// @param partyB 对手方（执行者）地址
    /// @param grossAmount reward + 协议费（USDC 原始值）
    /// @param verifier Verifier 合约地址
    /// @param verifierFee 验证费用（USDC，6 位小数）
    /// @param deadline 签名有效期（Unix 秒）
    /// @param sig Verifier 的 EIP-712 签名
    /// @param tweet_id 要被引用的推文 ID（字符串）
    /// @param quoter_username B 的 X 用户名；前导 @ 会被去除，字母会被转为小写
    function createDeal(
        address partyB,
        uint96  grossAmount,
        address verifier,
        uint96  verifierFee,
        uint256 deadline,
        bytes calldata sig,
        string calldata tweet_id,
        string calldata quoter_username
    ) external returns (uint256 dealIndex) {
        // --- 参数校验 ---
        if (grossAmount <= PROTOCOL_FEE) revert InvalidParams();
        if (verifierFee > grossAmount - PROTOCOL_FEE) revert InvalidParams();
        if (partyB == address(0)) revert InvalidParams();
        if (msg.sender == partyB) revert InvalidParams();

        if (verifier == address(0)) revert InvalidParams();
        if (msg.sender == verifier || partyB == verifier) revert InvalidParams();
        if (verifier.code.length == 0) revert VerifierNotContract();
        if (sig.length == 0) revert InvalidVerifierSignature();
        if (deadline < block.timestamp) revert SignatureExpired();

        // 规范化用户名：去除前导 @，转为小写
        string memory canonicalUsername = _canonicalizeUsername(quoter_username);
        if (bytes(tweet_id).length == 0 || bytes(canonicalUsername).length == 0) revert InvalidParams();

        // 调用 Spec.check() 验证 Verifier 签名 — 证明这些参数确实是 Verifier 允诺的
        _verifyVerifierSignature(verifier, tweet_id, canonicalUsername, verifierFee, deadline, sig);

        // --- USDC 转入托管 ---
        if (!IERC20(USDC).transferFrom(msg.sender, address(this), grossAmount)) revert TransferFailed();

        // --- 创建交易记录 ---
        {
            address[] memory traders = new address[](2);
            traders[0] = msg.sender;
            traders[1] = partyB;
            address[] memory verifiers = new address[](1);
            verifiers[0] = verifier;
            dealIndex = _recordStart(traders, verifiers);
        }

        {
            Deal storage d = deals[dealIndex];
            d.partyA = msg.sender;
            d.partyB = partyB;
            d.verifier = verifier;
            d.amount = grossAmount - PROTOCOL_FEE;
            d.verifierFee = verifierFee;
            d.tweet_id = tweet_id;
            d.quoter_username = canonicalUsername;
            d.signatureDeadline = deadline;
            d.verifierSignature = sig;
            d.state = uint8(State.Created);
            d.stageTimestamp = uint48(block.timestamp);
        }

        _emitStateChanged(dealIndex, uint8(State.Created));
    }

    // ===================== 核心流程 =====================

    /// @notice B 接受交易
    /// @dev 接受时支付协议费给 FeeCollector，标记交易为已激活。
    ///      此后交易不可取消，资金正式进入执行流程。
    function accept(uint256 dealIndex)
        external
        onlyB(dealIndex)
        inState(dealIndex, State.Created)
        notTimedOut(dealIndex)
    {
        Deal storage d = deals[dealIndex];
        uint96 fee = PROTOCOL_FEE;
        d.state = uint8(State.Accepted);
        d.stageTimestamp = uint48(block.timestamp);

        // 协议费在此时支付（激活后）— 如果取消则不会走到这里，全额退款
        if (!IERC20(USDC).transfer(FEE_COLLECTOR, fee)) revert TransferFailed();

        emit ProtocolFeePaid(dealIndex, fee);
        emit DealFeeSplit(dealIndex, d.amount + fee, fee, d.amount);
        _recordActivated(dealIndex);
        emit DealAccepted(dealIndex);
        _emitStateChanged(dealIndex, uint8(State.Accepted));
    }

    /// @notice B 声称已完成引用推文，提交 quote_tweet_id
    /// @dev quote_tweet_id 不能为空，将存储供 Verifier 验证使用。
    function claimDone(uint256 dealIndex, string calldata quote_tweet_id)
        external
        onlyB(dealIndex)
        inState(dealIndex, State.Accepted)
        notTimedOut(dealIndex)
    {
        if (bytes(quote_tweet_id).length == 0) revert InvalidParams();

        Deal storage d = deals[dealIndex];
        d.quote_tweet_id = quote_tweet_id;
        d.state = uint8(State.ClaimedDone);
        d.stageTimestamp = uint48(block.timestamp);

        emit DealClaimedDone(dealIndex);
        _emitStateChanged(dealIndex, uint8(State.ClaimedDone));
    }

    /// @notice A 手动确认并直接付款给 B（跳过验证）
    /// @dev 仅在未请求验证时可用。验证进行中不可调用。
    function confirmAndPay(uint256 dealIndex)
        external
        onlyA(dealIndex)
        inState(dealIndex, State.ClaimedDone)
    {
        Deal storage d = deals[dealIndex];
        if (d.verificationRequested) revert VerificationPending();

        uint96 amt = d.amount;
        d.amount = 0;
        d.state = uint8(State.Completed);

        if (!IERC20(USDC).transfer(d.partyB, amt)) revert TransferFailed();

        emit DealCompleted(dealIndex, amt);
        _emitStateChanged(dealIndex, uint8(State.Completed));
        _recordEnd(dealIndex);
    }

    // ===================== 取消（Created → Cancelled） =====================

    /// @notice A 取消 B 尚未接受的交易（Created 状态 + 已超时）
    /// @dev 全额退还 grossAmount（包括协议费，因为此时尚未激活）。
    function cancelDeal(uint256 dealIndex)
        external
        onlyA(dealIndex)
        inState(dealIndex, State.Created)
    {
        if (!_isTimedOut(dealIndex)) revert NotTimedOut();

        Deal storage d = deals[dealIndex];
        uint96 amt = d.amount + PROTOCOL_FEE;
        d.amount = 0;
        d.state = uint8(State.Cancelled);

        _recordCancelled(dealIndex);
        _emitStateChanged(dealIndex, uint8(State.Cancelled));

        if (amt > 0) {
            if (!IERC20(USDC).transfer(d.partyA, amt)) revert TransferFailed();
        }
    }

    // ===================== 验证 =====================

    /// @notice Trader 触发验证（调用者通过 approve 支付验证费）
    /// @dev 流程：权限检查 → 状态检查 → CEI 模式（先改状态再转账）→ 发出 VerificationRequested
    ///      Verifier 监听 VerificationRequested 事件后，通过 verificationParams 获取参数执行验证。
    function requestVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        override
        inState(dealIndex, State.ClaimedDone)
        onlySlot0(verificationIndex)
    {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.partyA && msg.sender != d.partyB) revert NotAorB();
        if (d.verificationRequested) revert AlreadyRequested();
        if (_isTimedOut(dealIndex)) revert AlreadyTimedOut();

        uint96 fee = d.verifierFee;
        address verifier = d.verifier;

        if (IERC20(USDC).allowance(msg.sender, address(this)) < fee) revert InsufficientAllowance();
        if (IERC20(USDC).balanceOf(msg.sender) < fee) revert InsufficientBalance();

        // 先改状态（CEI 模式）
        d.verificationRequested = true;
        d.isRequesterA = (msg.sender == d.partyA);
        d.verificationTimestamp = uint48(block.timestamp);

        // 调用者支付验证费到合约托管（Verifier 提交结果后才转出）
        if (!IERC20(USDC).transferFrom(msg.sender, address(this), fee)) revert TransferFailed();

        // 发出 VerificationRequested 事件（Verifier 通过 verificationParams 读取完整参数）
        emit VerificationRequested(dealIndex, verificationIndex, verifier);
    }

    /// @notice Verifier 通过 reportResult → onReportResult 提交验证结果
    /// @dev 核心分支逻辑：
    ///      result > 0 → 通过，付款给 B
    ///      result < 0 → 失败，B 违约
    ///      result == 0 → 不确定，进入协商
    ///      所有状态变更在转账之前完成（CEI 模式）。
    function onReportResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata /* reason */) external override onlySlot0(verificationIndex) {
        Deal storage d = deals[dealIndex];

        // 安全检查：只有指定的 Verifier 合约可以调用
        if (msg.sender != d.verifier) revert NotVerifier();
        if (d.state != uint8(State.ClaimedDone)) revert InvalidState();
        if (!d.verificationRequested) revert NotRequested();

        // 清除验证状态（所有分支通用）
        d.verificationRequested = false;
        d.verificationTimestamp = 0;

        uint96 vFee = d.verifierFee;

        // --- 生效：在转账之前完成所有状态变更（CEI 模式） ---
        uint96 transferToB = 0;

        if (result > 0) {
            // 验证通过 → 付款给 B
            transferToB = d.amount;
            d.amount = 0;
            d.state = uint8(State.Completed);
        } else if (result < 0) {
            // 验证失败 → B 违约
            d.state = uint8(State.Violated);
            d.violator = d.partyB;
        } else {
            // result == 0 → 不确定，进入协商
            d.state = uint8(State.Settling);
            d.stageTimestamp = uint48(block.timestamp);
        }

        // --- 事件 ---
        emit VerificationReceived(dealIndex, verificationIndex, msg.sender, result);

        if (result > 0) {
            emit DealCompleted(dealIndex, transferToB);
            _emitStateChanged(dealIndex, uint8(State.Completed));
            _recordEnd(dealIndex);
        } else if (result < 0) {
            _emitViolated(dealIndex, d.partyB);
            _emitStateChanged(dealIndex, uint8(State.Violated));
            _recordDispute(dealIndex);
        } else {
            _emitStateChanged(dealIndex, uint8(State.Settling));
            emit SettlingStarted(dealIndex);
        }

        // --- 交互：所有转账最后执行 ---
        if (vFee > 0) {
            if (!IERC20(USDC).transfer(msg.sender, vFee)) revert TransferFailed();
        }
        if (transferToB > 0) {
            if (!IERC20(USDC).transfer(d.partyB, transferToB)) revert TransferFailed();
        }
    }

    // ===================== 验证重置 =====================

    /// @notice Verifier 超时后重置验证。
    ///         将托管的验证费退还给请求方，然后进入协商状态。
    /// @dev 保护了付费请求验证的一方，避免因 Verifier 不作为而损失费用。
    function resetVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        inState(dealIndex, State.ClaimedDone)
        onlySlot0(verificationIndex)
    {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.partyA && msg.sender != d.partyB) revert NotAorB();
        if (!d.verificationRequested) revert NotRequested();
        if (block.timestamp <= uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT)
            revert VerificationNotTimedOut();

        address requester = d.isRequesterA ? d.partyA : d.partyB;
        uint96 vFee = d.verifierFee;

        // --- 生效：所有状态变更先执行（CEI 模式） ---
        d.verificationRequested = false;
        d.verificationTimestamp = 0;
        d.state = uint8(State.Settling);
        d.stageTimestamp = uint48(block.timestamp);

        // --- 事件 ---
        emit VerificationReset(dealIndex, verificationIndex, d.verifier);
        emit SettlingStarted(dealIndex);
        _emitStateChanged(dealIndex, uint8(State.Settling));

        // --- 交互：转账最后执行 ---
        if (vFee > 0) {
            if (!IERC20(USDC).transfer(requester, vFee)) revert TransferFailed();
        }
    }

    // ===================== 协商 =====================

    /// @notice 提出协商方案：amountToA 是给 A 的金额（剩余归 B）
    /// @dev 任一方都可以提出。对方可以通过提出不同方案来拒绝。
    function proposeSettlement(uint256 dealIndex, uint96 amountToA)
        external
        inState(dealIndex, State.Settling)
    {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.partyA && msg.sender != d.partyB) revert NotAorB();
        if (amountToA > d.amount) revert InvalidSettlement();

        settlements[dealIndex] = Settlement({
            proposer: msg.sender,
            amountToA: amountToA
        });

        emit SettlementProposed(dealIndex, msg.sender, amountToA);
    }

    /// @notice 确认对方的协商提案
    /// @dev 提案方不能确认自己的提案，必须由对方确认。
    function confirmSettlement(uint256 dealIndex)
        external
        inState(dealIndex, State.Settling)
    {
        Deal storage d = deals[dealIndex];
        Settlement storage stl = settlements[dealIndex];

        if (msg.sender != d.partyA && msg.sender != d.partyB) revert NotAorB();
        if (msg.sender == stl.proposer) revert ProposerCannotConfirm();
        if (stl.proposer == address(0)) revert InvalidSettlement();

        uint96 toA = stl.amountToA;
        uint96 toB = d.amount - toA;
        d.amount = 0;
        d.state = uint8(State.Completed);

        delete settlements[dealIndex];

        if (toA > 0) {
            if (!IERC20(USDC).transfer(d.partyA, toA)) revert TransferFailed();
        }
        if (toB > 0) {
            if (!IERC20(USDC).transfer(d.partyB, toB)) revert TransferFailed();
        }

        emit SettlementConfirmed(dealIndex);
        _emitStateChanged(dealIndex, uint8(State.Completed));
        _recordEnd(dealIndex);
    }

    /// @notice A/B 未能在协商超时前达成一致时，任何人都可以触发将资金没收到 FeeCollector。
    /// @dev 这是协商阶段的兜底机制，激励双方积极协商。
    function triggerSettlementTimeout(uint256 dealIndex)
        external
        inState(dealIndex, State.Settling)
    {
        Deal storage d = deals[dealIndex];
        if (block.timestamp <= uint256(d.stageTimestamp) + SETTLING_TIMEOUT) revert SettlementNotTimedOut();

        uint96 seized = d.amount;
        d.amount = 0;
        d.state = uint8(State.Completed);
        delete settlements[dealIndex];

        if (seized > 0) {
            if (!IERC20(USDC).transfer(FEE_COLLECTOR, seized)) revert TransferFailed();
            emit FundsSeized(dealIndex, seized);
        }

        emit SettlementTimedOutSeized(dealIndex, seized);
        _emitStateChanged(dealIndex, uint8(State.Completed));
        _recordEnd(dealIndex);
    }

    // ===================== 超时 =====================

    /// @notice 触发当前阶段的超时处理
    /// @dev Accepted 超时：B 未 claimDone → B 违约
    ///      ClaimedDone 超时：A 未确认 → 自动付款给 B
    function triggerTimeout(uint256 dealIndex) external {
        Deal storage d = deals[dealIndex];
        if (!_isTimedOut(dealIndex)) revert NotTimedOut();

        State s = State(d.state);

        if (s == State.Accepted) {
            // B 未 claimDone → B 违约
            if (msg.sender != d.partyA) revert NotPartyA();
            d.state = uint8(State.Violated);
            d.violator = d.partyB;
            _emitViolated(dealIndex, d.partyB);
            _emitStateChanged(dealIndex, uint8(State.Violated));
            _recordDispute(dealIndex);

        } else if (s == State.ClaimedDone) {
            // A 未确认 → 自动付款给 B（A 的不作为视为默认确认）
            if (msg.sender != d.partyB) revert NotPartyB();
            if (d.verificationRequested) revert VerificationPending();
            uint96 amt = d.amount;
            d.amount = 0;
            d.state = uint8(State.Completed);
            if (!IERC20(USDC).transfer(d.partyB, amt)) revert TransferFailed();
            emit DealCompleted(dealIndex, amt);
            _emitStateChanged(dealIndex, uint8(State.Completed));
            _recordEnd(dealIndex);

        } else {
            revert InvalidState();
        }
    }

    /// @notice 违约后提取资金
    /// @dev 仅非违约方可调用。违约方不能提取。
    function withdraw(uint256 dealIndex) external inState(dealIndex, State.Violated) {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.partyA && msg.sender != d.partyB) revert NotAorB();
        if (msg.sender == d.violator) revert ViolatorCannot();
        if (d.amount == 0) revert NoFunds();

        uint96 amt = d.amount;
        d.amount = 0;

        if (!IERC20(USDC).transfer(msg.sender, amt)) revert TransferFailed();

        emit Withdrawn(dealIndex, msg.sender, amt);
    }

    // ===================== 内部辅助函数 =====================

    /// @dev 验证 Verifier 的 EIP-712 签名
    ///      1. 检查 Verifier.spec() == REQUIRED_SPEC（确保使用正确的 Spec）
    ///      2. 调用 Spec.check() 验证签名（证明参数确实是 Verifier 允诺的）
    function _verifyVerifierSignature(
        address verifier,
        string calldata tweet_id,
        string memory canonicalUsername,
        uint96 fee,
        uint256 deadline,
        bytes calldata sig
    ) internal view {
        address verifierSpec = IVerifier(verifier).spec();
        if (verifierSpec != REQUIRED_SPEC) revert InvalidSpecAddress();
        if (!XQuoteVerifierSpec(verifierSpec).check(verifier, tweet_id, canonicalUsername, uint256(fee), deadline, sig))
            revert InvalidVerifierSignature();
    }

    /// @dev 检查当前阶段是否已超时
    ///      Settling 状态使用 SETTLING_TIMEOUT（12 小时），其他状态使用 STAGE_TIMEOUT（30 分钟）
    function _isTimedOut(uint256 dealIndex) internal view returns (bool) {
        Deal storage d = deals[dealIndex];
        uint256 timeout = d.state == uint8(State.Settling) ? SETTLING_TIMEOUT : STAGE_TIMEOUT;
        return block.timestamp > uint256(d.stageTimestamp) + timeout;
    }

    /// @dev 规范化 X 用户名：去除前导 at 符号，转为小写
    ///      例如 "at+ElonMusk" → "elonmusk"
    function _canonicalizeUsername(string memory value) internal pure returns (string memory) {
        bytes memory raw = bytes(value);
        uint256 start = 0;

        // 跳过前导 @
        while (start < raw.length && raw[start] == 0x40) {
            unchecked {
                ++start;
            }
        }

        // 逐字符转小写（A-Z → a-z）
        bytes memory normalized = new bytes(raw.length - start);
        for (uint256 i = start; i < raw.length; ++i) {
            bytes1 char_ = raw[i];
            if (char_ >= 0x41 && char_ <= 0x5A) {
                char_ = bytes1(uint8(char_) + 32);
            }
            normalized[i - start] = char_;
        }

        return string(normalized);
    }

    // ===================== 查询函数 =====================

    /// @notice 获取当前阶段的剩余时间（秒）
    /// @dev 如果正在验证中，返回验证超时的剩余时间；
    ///      如果在 Settling 状态，返回协商超时的剩余时间；
    ///      其他情况返回阶段超时的剩余时间。
    function timeRemaining(uint256 dealIndex) external view returns (uint256) {
        Deal storage d = deals[dealIndex];
        uint256 deadline_;
        if (d.verificationRequested && d.verificationTimestamp > 0) {
            deadline_ = uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT;
        } else if (d.state == uint8(State.Settling)) {
            deadline_ = uint256(d.stageTimestamp) + SETTLING_TIMEOUT;
        } else {
            deadline_ = uint256(d.stageTimestamp) + STAGE_TIMEOUT;
        }
        if (block.timestamp >= deadline_) return 0;
        return deadline_ - block.timestamp;
    }

    /// @notice 检查验证是否已超时
    function isVerificationTimedOut(uint256 dealIndex) external view returns (bool) {
        Deal storage d = deals[dealIndex];
        if (!d.verificationRequested) return false;
        return block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT;
    }

    /// @notice 获取协商提案信息
    /// @return proposer 提案方地址
    /// @return amountToA 提议给 A 的金额
    /// @return amountToB 提议给 B 的金额（总额 - amountToA）
    function settlement(uint256 dealIndex) external view returns (
        address proposer,
        uint96  amountToA,
        uint96  amountToB
    ) {
        Settlement storage stl = settlements[dealIndex];
        uint96 total = deals[dealIndex].amount;
        return (stl.proposer, stl.amountToA, total - stl.amountToA);
    }

    /// @notice 检查交易是否已超时
    function isTimedOut(uint256 dealIndex) external view returns (bool) {
        return _isTimedOut(dealIndex);
    }

    // ===================== 标准身份标识 =====================

    /// @notice 返回合约名称
    function name() external pure override returns (string memory) {
        return "X Quote Tweet Deal";
    }

    /// @notice 返回合约描述
    function description() external pure override returns (string memory) {
        return "Pay USDC to get a tweet quoted on X. 2-party (payer + quoter). On-chain verifier for auto-completion or manual confirm. 30min stage timeout, settlement on dispute.";
    }

    /// @notice 返回分类标签
    function tags() external pure override returns (string[] memory) {
        string[] memory tags = new string[](2);
        tags[0] = "x";
        tags[1] = "quote";
        return tags;
    }

    /// @notice 返回交易合约版本号
    function version() external pure override returns (string memory) {
        return "1.0";
    }

    /// @notice 协议费金额
    function protocolFee() external view override returns (uint96) {
        return PROTOCOL_FEE;
    }

    // ===================== 验证查询 =====================

    /// @notice 返回每个验证槽位所需的 Spec 地址
    /// @dev 此合约恰好有 1 个验证槽位（索引 0）
    function requiredSpecs() external view override returns (address[] memory) {
        address[] memory specs = new address[](1);
        specs[0] = REQUIRED_SPEC;
        return specs;
    }

    /// @notice 返回指定验证槽位的完整验证参数
    /// @dev specParams = abi.encode(tweet_id, quoter_username, quote_tweet_id)
    ///      其中 tweet_id 和 quoter_username 在 createDeal 时存入，
    ///      quote_tweet_id 在 claimDone 时由 B 提交。
    function verificationParams(uint256 dealIndex, uint256 verificationIndex)
        external view override
        onlySlot0(verificationIndex)
        returns (
            address verifier,
            uint256 fee,
            uint256 deadline,
            bytes memory sig,
            bytes memory specParams
        )
    {
        Deal storage d = deals[dealIndex];
        if (d.partyA == address(0)) revert InvalidParams();

        specParams = abi.encode(d.tweet_id, d.quoter_username, d.quote_tweet_id);

        return (d.verifier, uint256(d.verifierFee), d.signatureDeadline, d.verifierSignature, specParams);
    }

    // ===================== 操作指南 =====================

    /// @notice 返回 Markdown 格式的操作指南
    function instruction() external view override returns (string memory) {
        return
            "# X Quote Tweet Deal\n\n"
            "## Overview\n\n"
            "Pay USDC to get a tweet quoted on X. 2-party (payer + quoter). On-chain verifier for auto-completion or manual confirm. 30min stage timeout, settlement on dispute.\n\n"
            "- **A (Initiator)**: Specifies a tweet + deposits USDC reward\n"
            "- **B (Executor)**: Quotes the tweet on X\n"
            "- **Settlement**: After A manually confirms or verifier auto-verifies, B receives the reward\n\n"
            "| Item | Value |\n"
            "|----|----|\n"
            "| Chain | Check `block.chainid` |\n"
            "| Token | USDC (decimals=6), address available via `USDC()` |\n"
            "| Amount format | Raw value x10^6, e.g. 1.5 USDC = `1500000` |\n\n"
            "---\n\n"
            "## Price Negotiation\n\n"
            "Before creating a deal, determine whether you are A (payer) or B (quoter), then negotiate B's reward (net amount). The value of quoting depends on B's influence:\n\n"
            "- **A (Offer)**: Evaluate based on B's follower count, engagement rate, etc. Higher influence warrants a higher offer.\n"
            "- **B (Evaluate)**: Judge whether the offer is fair based on your influence; counter-offer if not.\n"
            "- **Bottom line**: Either party may walk away if the price is unacceptable.\n\n"
            "---\n\n"
            "## createDeal Parameters\n\n"
            "| Parameter | Type | Description |\n"
            "|------|------|------|\n"
            "| partyB | address | Executor (quoter) address |\n"
            "| grossAmount | uint96 | Negotiated reward + protocol fee (USDC raw value). Call `protocolFee()` to get the fee, then grossAmount = reward + fee |\n"
            "| verifier | address | Verifier contract address |\n"
            "| verifierFee | uint96 | Verification fee (USDC raw value) |\n"
            "| deadline | uint256 | Verifier signature validity (Unix seconds) |\n"
            "| sig | bytes | Verifier EIP-712 signature |\n"
            "| tweet_id | string | Tweet ID to be quoted |\n"
            "| quoter_username | string | B's X username. Leading @ and mixed case are accepted; the contract strips leading @ and lowercases internally |\n\n"
            "**Prerequisites**:\n"
            "1. Confirm B has not already quoted the target tweet, otherwise the deal is meaningless\n"
            "2. Both parties have agreed on B's reward, tweet_id, quoter_username. A calls `protocolFee()` to get the protocol fee, grossAmount = reward + protocol fee\n"
            "3. USDC `approve(contract address, reward + protocol fee + verification fee)`, i.e., grossAmount + verifierFee\n"
            "4. Obtain verifier signature via `request_sign` (sig + fee)\n\n"
            "> On creation, `grossAmount` is transferred to the contract in full; the protocol fee is only sent to `FeeCollector` after B calls `accept`. If B does not accept and the deal is cancelled, both protocol fee and reward are refunded to A.\n\n"
            "## dealStatus Action Guide\n\n"
            "`dealStatus(dealIndex)` returns the current business status code. Refer to the table below for actions:\n\n"
            "| Code | Meaning | Action |\n"
            "|----|------|------|\n"
            "| 0 | A: Waiting for B to accept | Wait; on timeout: `cancelDeal(dealIndex)` to reclaim funds |\n"
            "| 1 | B: Accept the task | `accept(dealIndex)` |\n"
            "| 2 | A: Waiting for B to quote tweet | Wait |\n"
            "| 3 | B: Quote the tweet, then declare done | Quote tweet, then `claimDone(dealIndex, quote_tweet_id)` (`quote_tweet_id` required) |\n"
            "| 4 | A: B declared done | Prefer `requestVerification(dealIndex, 0)` if verifier is available and affordable; otherwise verify manually then `confirmAndPay(dealIndex)` |\n"
            "| 5 | B: Waiting for A to confirm | Wait; if A times out: `triggerTimeout(dealIndex)` for auto-payment |\n"
            "| 6 | A/B: Verification in progress | Wait for result |\n"
            "| 7 | Verifier: Submit result | Verifier-only action |\n"
            "| 8 | Completed | Terminal, no action |\n"
            "| 9 | You are in breach | Terminal, no action |\n"
            "| 10 | Counterparty violated | `withdraw(dealIndex)` to reclaim funds |\n"
            "| 11 | Verifier: No action needed | -- |\n"
            "| 12 | Not a participant | Unrelated to this deal |\n"
            "| 13 | Verifier timed out | `resetVerification(dealIndex, 0)` to enter settlement |\n"
            "| 14 | Settling | `proposeSettlement(dealIndex, amountToA)` |\n"
            "| 15 | Counterparty proposed settlement | `confirmSettlement(dealIndex)` to accept, or `proposeSettlement` to counter-propose |\n"
            "| 16 | Settlement timed out (12h) | `triggerSettlementTimeout(dealIndex)` |\n"
            "| 17 | Cancelled | Terminal, A has reclaimed funds |\n\n"
            "**Quick reference**:\n"
            "- Codes **2, 5, 6**: Wait for the other party, no action needed\n"
            "- Codes **8, 9, 11, 12, 17**: Terminal or unrelated\n"
            "- Others: **Action required**, follow the table above\n\n"
            "> **Timeouts**: 30 minutes per stage (Settling: 12 hours). Use `getTimeRemaining(dealIndex)` to query remaining seconds.\n\n"
            "> **Verification flow (code 4)**:\n"
            "> 1. `requestVerification(dealIndex, 0)`\n"
            "> 2. **Must** call `notify_verifier(verifier_address, dealContract, dealIndex, verificationIndex)` to notify the verifier\n"
            "> 3. Passed: auto-payment to B; failed: B is in breach. Verification fee is non-refundable.\n\n"
            "> **Settlement semantics (code 14)**: In `proposeSettlement(dealIndex, amountToA)`, amountToA is **the amount A receives** (x10^6); the remainder goes to B.\n";
    }

    // ===================== 状态查询 =====================

    /// @notice 平台级统一交易阶段
    /// @dev 0=NotFound, 1=Active, 2=Success, 3=Failed, 4=Refunding, 5=Cancelled
    function phase(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.partyA == address(0)) return 0; // NotFound

        State s = State(d.state);

        if (s == State.Completed) return 2; // Success
        if (s == State.Violated) return 3;  // Failed
        if (s == State.Settling) return 4;  // Refunding
        if (s == State.Cancelled) return 5; // Cancelled

        return 1; // Active（Created、Accepted、ClaimedDone）
    }

    /// @notice 业务级交易状态码（角色感知）
    /// @dev 根据 msg.sender 是 A、B、Verifier 还是外部人返回不同的操作码。
    ///      配合 instruction() 使用，告诉每个参与者"你现在该做什么"。
    function dealStatus(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];

        // 识别角色
        bool isA = (msg.sender == d.partyA);
        bool isB = (msg.sender == d.partyB);
        bool isV = (msg.sender == d.verifier);
        if (!isA && !isB && !isV) return 12; // 非参与方

        State s = State(d.state);

        // Created 状态：A 等待 B 接受
        if (s == State.Created) {
            if (_isTimedOut(dealIndex)) {
                if (isA) return 0; // A 可以 cancelDeal
                return 12;
            }
            if (isA) return 0;
            if (isB) return 1;
            return 11; // Verifier 无需行动
        }

        // Accepted 状态：等待 B 引用推文
        if (s == State.Accepted) {
            if (isA) return 2; // A 等待
            if (isB) return 3; // B 去引用推文然后 claimDone
            return 11;
        }

        // ClaimedDone 状态：等待 A 确认或验证
        if (s == State.ClaimedDone) {
            if (d.verificationRequested) {
                // 检查 Verifier 是否已超时
                if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) {
                    if (isA || isB) return 13; // Verifier 超时，可以 resetVerification
                    return 11;
                }
                if (isV) return 7; // Verifier 需要提交结果
                return 6; // A 或 B 等待验证结果
            }
            if (isA) return 4; // A 可以确认/请求验证
            if (isB) return 5; // B 等待 A 确认
            return 11;
        }

        // Settling 状态：协商中
        if (s == State.Settling) {
            if (!isA && !isB) return 12; // Verifier/其他人不参与协商
            if (_isTimedOut(dealIndex)) return 16; // 协商超时
            Settlement storage stl = settlements[dealIndex];
            if (stl.proposer != address(0) && stl.proposer != msg.sender) return 15; // 对方已提案
            return 14; // 可以提案
        }

        // 终态
        if (s == State.Completed) {
            return 8;
        }

        if (s == State.Cancelled) {
            return 17;
        }

        // Violated 状态
        if (msg.sender == d.violator) return 9;  // 你是违约方
        if (isA || isB) return 10;                 // 对方违约，你可以 withdraw
        return 8; // Verifier 看到的是已终止
    }

    /// @notice 指定索引的交易是否存在
    function dealExists(uint256 dealIndex) external view override returns (bool) {
        return deals[dealIndex].partyA != address(0);
    }
}
