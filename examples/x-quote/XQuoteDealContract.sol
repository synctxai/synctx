// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealBase.sol";
import "./IVerifier.sol";
import "./XQuoteVerifierSpec.sol";
import "./IERC20.sol";
import "./Initializable.sol";
import "./MetaTxMixin.sol";
import "./BindingAttestation.sol";


/// @title XQuoteDealContract - X 引用推文交易合约
/// @notice 单合约管理所有交易。feeToken 通过 setFeeToken() 一次性设置（跨链统一地址）。
/// @dev USDC approve · 紧凑存储 · 自定义错误 · 直接支付
///      统一 dealStatus — status 字段直接存储 dealStatus 基础值，无内部 State 枚举
///
///      交易流程概览：
///      1. A 创建交易，存入 USDC（reward + protocolFee），指定 B 和 Verifier
///      2. B 接受交易（protocolFee 此时支付给 FeeCollector）
///      3. B 在 X 上引用推文，然后调用 claimDone 提交 quote_tweet_id
///      4. A 手动确认付款，或请求 Verifier 自动验证
///      5. 如果验证不确定或 Verifier 超时，进入协商阶段
contract XQuoteDealContract is DealBase, Initializable, MetaTxMixin("XQuoteDeal", "1") {

    // ===================== 错误 =====================

    error NotPartyA();
    error NotPartyB();
    error NotVerifier();
    error NotAorB();
    error InvalidStatus();
    error NotTimedOut();
    error AlreadyTimedOut();
    error NoFunds();
    error InvalidParams();
    error TransferFailed();
    error ViolatorCannot();
    error VerificationNotTimedOut();
    error InvalidSettlement();
    error SettlementNotTimedOut();
    error FeeTooLow();
    error InvalidFeeCollector();
    error VerifierNotContract();
    error InvalidVerifierSignature();
    error SignatureExpired();
    error InvalidVerificationIndex();
    error InvalidSpecAddress();
    error NotVerified();
    error InvalidBindingSignature();
    error Reentrancy();
    error FeeTokenNotSet();
    error VersionMismatch();

    // ===================== dealStatus 常量 =====================
    // 基础值（可写入存储）和派生值（仅由 dealStatus() 运行时计算）。
    //
    //   存储基础值          dealStatus 派生值
    //   ─────────────       ──────────────────
    //   WAITING_ACCEPT (0)  → ACCEPT_TIMED_OUT (1)
    //   WAITING_CLAIM  (2)  → CLAIM_TIMED_OUT (3)
    //   WAITING_CONFIRM(4)  → CONFIRM_TIMED_OUT (5)
    //   VERIFYING      (6)  → VERIFIER_TIMED_OUT (7)
    //   SETTLING       (8)  → SETTLEMENT_PROPOSED (9), SETTLEMENT_TIMED_OUT (10)
    //   COMPLETED     (11)
    //   VIOLATED      (12)
    //   CANCELLED     (13)
    //   FORFEITED     (14)
    //   NOT_FOUND    (255)  — deal 不存在

    uint8 constant WAITING_ACCEPT       = 0;
    uint8 constant ACCEPT_TIMED_OUT     = 1;
    uint8 constant WAITING_CLAIM        = 2;
    uint8 constant CLAIM_TIMED_OUT      = 3;
    uint8 constant WAITING_CONFIRM      = 4;
    uint8 constant CONFIRM_TIMED_OUT    = 5;
    uint8 constant VERIFYING            = 6;
    uint8 constant VERIFIER_TIMED_OUT   = 7;
    uint8 constant SETTLING             = 8;
    uint8 constant SETTLEMENT_PROPOSED  = 9;
    uint8 constant SETTLEMENT_TIMED_OUT = 10;
    uint8 constant COMPLETED            = 11;
    uint8 constant VIOLATED             = 12;
    uint8 constant CANCELLED            = 13;
    uint8 constant FORFEITED            = 14;
    uint8 constant NOT_FOUND            = 255;

    // ===================== 类型 =====================

    /// @dev 紧凑存储到最少的存储槽。
    ///      单验证槽位特化（requiredSpecs().length == 1）。
    struct Deal {
        // 槽 1（28/32 字节）
        address partyA;                   // 20 字节 — A 方地址（发起者/付款方）
        uint48  stageTimestamp;           // 6 字节  — 当前阶段开始时间
        uint8   status;                   // 1 字节  — dealStatus 基础值
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
        uint64  quoter_user_id;           // 绑定的 X/Twitter immutable user_id
        string  quote_tweet_id;           // B 的引用推文 ID，由 claimDone 设置
        bytes   verifierSignature;        // EIP-712 签名（槽位 0，65 字节）
    }

    /// @dev 协商提案，仅在 Settling 状态使用
    struct Settlement {
        address proposer;     // 20 字节 — 提案方
        uint96  amountToA;    // 12 字节 — 提议给 A 的金额（剩余归 B）
        uint256 version;      // 提案版本号，每次提案 +1
    }

    // ===================== 常量 =====================

    uint96 public constant MIN_PROTOCOL_FEE = 10_000;
    uint256 public constant STAGE_TIMEOUT = 30 minutes;
    uint256 public constant VERIFICATION_TIMEOUT = 30 minutes;
    uint256 public constant SETTLING_TIMEOUT = 12 hours;
    uint256 public constant CONFIRM_GRACE_PERIOD = 1 hours;

    address public immutable FEE_COLLECTOR;
    uint96 public immutable PROTOCOL_FEE;
    address public immutable REQUIRED_SPEC;
    BindingAttestation public immutable BINDING_ATTESTATION;

    // ===================== 存储 =====================

    uint256 private _lock = 1;

    mapping(uint256 => Deal) internal deals;
    mapping(uint256 => Settlement) internal settlementByA;
    mapping(uint256 => Settlement) internal settlementByB;

    // ===================== BySig TYPEHASH 常量 =====================

    bytes32 private constant _CREATE_DEAL_TYPEHASH = keccak256(
        "CreateDealBySig(address partyB,uint96 grossAmount,address verifier,"
        "uint96 verifierFee,uint256 verifierDeadline,bytes32 verifierSigHash,"
        "string tweet_id,uint64 quoterUserId,bytes32 bindingSigHash,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant _ACCEPT_TYPEHASH = keccak256(
        "AcceptBySig(uint256 dealIndex,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant _CLAIM_DONE_TYPEHASH = keccak256(
        "ClaimDoneBySig(uint256 dealIndex,string quote_tweet_id,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant _CONFIRM_AND_PAY_TYPEHASH = keccak256(
        "ConfirmAndPayBySig(uint256 dealIndex,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant _REQUEST_VERIFICATION_TYPEHASH = keccak256(
        "RequestVerificationBySig(uint256 dealIndex,uint256 verificationIndex,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant _PROPOSE_SETTLEMENT_TYPEHASH = keccak256(
        "ProposeSettlementBySig(uint256 dealIndex,uint96 amountToA,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant _CONFIRM_SETTLEMENT_TYPEHASH = keccak256(
        "ConfirmSettlementBySig(uint256 dealIndex,uint256 expectedVersion,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    // ===================== 修饰器 =====================

    modifier onlyA(uint256 dealIndex) {
        if (msg.sender != deals[dealIndex].partyA) revert NotPartyA();
        _;
    }

    modifier onlyB(uint256 dealIndex) {
        if (msg.sender != deals[dealIndex].partyB) revert NotPartyB();
        _;
    }

    modifier atStatus(uint256 dealIndex, uint8 s) {
        if (deals[dealIndex].status != s) revert InvalidStatus();
        _;
    }

    modifier notTimedOut(uint256 dealIndex) {
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();
        _;
    }

    modifier onlySlot0(uint256 verificationIndex) {
        if (verificationIndex != 0) revert InvalidVerificationIndex();
        _;
    }

    modifier nonReentrant() {
        if (_lock == 2) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ===================== 构造函数 =====================

    constructor(address feeCollector, uint96 protocolFee_, address requiredSpec, address bindingAttestation) {
        _setInitializer();
        if (feeCollector == address(0) || feeCollector == address(this) || feeCollector.code.length == 0) {
            revert InvalidFeeCollector();
        }
        if (protocolFee_ < MIN_PROTOCOL_FEE) revert FeeTooLow();
        if (requiredSpec == address(0) || requiredSpec.code.length == 0) revert InvalidSpecAddress();
        if (bindingAttestation == address(0) || bindingAttestation.code.length == 0) revert InvalidParams();
        FEE_COLLECTOR = feeCollector;
        PROTOCOL_FEE = protocolFee_;
        REQUIRED_SPEC = requiredSpec;
        BINDING_ATTESTATION = BindingAttestation(bindingAttestation);
    }

    // ===================== 创建交易 =====================

    /// @notice 创建交易（需要预先 approve USDC）
    /// @param quoterUserId B 的 Twitter immutable user_id
    /// @param bindingSig Platform 签发的 B 的绑定证明签名
    function createDeal(
        address partyB,
        uint96  grossAmount,
        address verifier,
        uint96  verifierFee,
        uint256 deadline,
        bytes calldata sig,
        string calldata tweet_id,
        uint64  quoterUserId,
        bytes calldata bindingSig
    ) external nonReentrant returns (uint256 dealIndex) {
        return _createDealCore(msg.sender, partyB, grossAmount, verifier, verifierFee, deadline, sig, tweet_id, quoterUserId, bindingSig);
    }

    /// @notice 创建交易（gasless BySig 版本）
    function createDealBySig(
        address partyB,
        uint96  grossAmount,
        address verifier,
        uint96  verifierFee,
        uint256 verifierDeadline,
        bytes calldata sig,
        string calldata tweet_id,
        uint64  quoterUserId,
        bytes calldata bindingSig,
        PermitData calldata permit,
        MetaTxProof calldata proof
    ) external nonReentrant returns (uint256 dealIndex) {
        bytes32 structHash = keccak256(abi.encode(
            _CREATE_DEAL_TYPEHASH,
            partyB, grossAmount, verifier,
            verifierFee, verifierDeadline, keccak256(sig),
            keccak256(bytes(tweet_id)), quoterUserId, keccak256(bindingSig),
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        _executePermit(permit, proof.signer);
        return _createDealCore(proof.signer, partyB, grossAmount, verifier, verifierFee, verifierDeadline, sig, tweet_id, quoterUserId, bindingSig);
    }

    function _createDealCore(
        address sender,
        address partyB,
        uint96  grossAmount,
        address verifier,
        uint96  verifierFee,
        uint256 deadline,
        bytes calldata sig,
        string calldata tweet_id,
        uint64  quoterUserId,
        bytes calldata bindingSig
    ) internal returns (uint256 dealIndex) {
        // --- 参数校验 ---
        if (feeToken == address(0)) revert FeeTokenNotSet();
        if (grossAmount <= PROTOCOL_FEE) revert InvalidParams();
        if (verifierFee > grossAmount - PROTOCOL_FEE) revert InvalidParams();
        if (partyB == address(0)) revert InvalidParams();
        if (sender == partyB) revert InvalidParams();

        if (verifier == address(0)) revert InvalidParams();
        if (sender == verifier || partyB == verifier) revert InvalidParams();
        if (verifier.code.length == 0) revert VerifierNotContract();
        if (sig.length == 0) revert InvalidVerifierSignature();
        if (deadline < block.timestamp) revert SignatureExpired();

        if (bytes(tweet_id).length == 0) revert InvalidParams();

        // 验证 B 的 Binding Attestation
        if (!BINDING_ATTESTATION.verify(partyB, quoterUserId, bindingSig)) revert InvalidBindingSignature();

        _verifyVerifierSignature(verifier, tweet_id, quoterUserId, verifierFee, deadline, sig);

        // --- USDC 转入托管 ---
        if (!IERC20(feeToken).transferFrom(sender, address(this), grossAmount)) revert TransferFailed();

        // --- 创建交易记录 ---
        {
            address[] memory traders = new address[](2);
            traders[0] = sender;
            traders[1] = partyB;
            address[] memory verifiers = new address[](1);
            verifiers[0] = verifier;
            dealIndex = _recordStart(traders, verifiers);
        }

        {
            Deal storage d = deals[dealIndex];
            d.partyA = sender;
            d.partyB = partyB;
            d.verifier = verifier;
            d.amount = grossAmount - PROTOCOL_FEE;
            d.verifierFee = verifierFee;
            d.tweet_id = tweet_id;
            d.quoter_user_id = quoterUserId;
            d.signatureDeadline = deadline;
            d.verifierSignature = sig;
            d.status = WAITING_ACCEPT;
            d.stageTimestamp = uint48(block.timestamp);
        }

        _emitStatusChanged(dealIndex, WAITING_ACCEPT);
    }

    // ===================== 核心流程 =====================

    /// @notice B 接受交易
    function accept(uint256 dealIndex)
        external
        nonReentrant
    {
        _acceptCore(msg.sender, dealIndex);
    }

    /// @notice B 接受交易（gasless BySig 版本）
    function acceptBySig(uint256 dealIndex, MetaTxProof calldata proof)
        external
        nonReentrant
    {
        bytes32 structHash = keccak256(abi.encode(
            _ACCEPT_TYPEHASH,
            dealIndex,
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        _acceptCore(proof.signer, dealIndex);
    }

    function _acceptCore(address sender, uint256 dealIndex) internal {
        Deal storage d = deals[dealIndex];
        if (sender != d.partyB) revert NotPartyB();
        if (d.status != WAITING_ACCEPT) revert InvalidStatus();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();

        uint96 fee = PROTOCOL_FEE;
        d.status = WAITING_CLAIM;
        d.stageTimestamp = uint48(block.timestamp);

        _emitPhaseChanged(dealIndex, 2); // → Active
        _emitStatusChanged(dealIndex, WAITING_CLAIM);

        if (!IERC20(feeToken).transfer(FEE_COLLECTOR, fee)) revert TransferFailed();
    }

    /// @notice B 声称已完成引用推文，提交 quote_tweet_id
    function claimDone(uint256 dealIndex, string calldata quote_tweet_id)
        external
        nonReentrant
    {
        _claimDoneCore(msg.sender, dealIndex, quote_tweet_id);
    }

    /// @notice B 声称已完成引用推文（gasless BySig 版本）
    function claimDoneBySig(uint256 dealIndex, string calldata quote_tweet_id, MetaTxProof calldata proof)
        external
        nonReentrant
    {
        bytes32 structHash = keccak256(abi.encode(
            _CLAIM_DONE_TYPEHASH,
            dealIndex,
            keccak256(bytes(quote_tweet_id)),
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        _claimDoneCore(proof.signer, dealIndex, quote_tweet_id);
    }

    function _claimDoneCore(address sender, uint256 dealIndex, string calldata quote_tweet_id) internal {
        Deal storage d = deals[dealIndex];
        if (sender != d.partyB) revert NotPartyB();
        if (d.status != WAITING_CLAIM) revert InvalidStatus();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();

        if (bytes(quote_tweet_id).length == 0) revert InvalidParams();

        d.quote_tweet_id = quote_tweet_id;
        d.status = WAITING_CONFIRM;
        d.stageTimestamp = uint48(block.timestamp);

        _emitStatusChanged(dealIndex, WAITING_CONFIRM);
    }

    /// @notice A 手动确认并直接付款给 B（跳过验证）
    function confirmAndPay(uint256 dealIndex)
        external
        nonReentrant
    {
        _confirmAndPayCore(msg.sender, dealIndex);
    }

    /// @notice A 手动确认并直接付款给 B（gasless BySig 版本）
    function confirmAndPayBySig(uint256 dealIndex, MetaTxProof calldata proof)
        external
        nonReentrant
    {
        bytes32 structHash = keccak256(abi.encode(
            _CONFIRM_AND_PAY_TYPEHASH,
            dealIndex,
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        _confirmAndPayCore(proof.signer, dealIndex);
    }

    function _confirmAndPayCore(address sender, uint256 dealIndex) internal {
        Deal storage d = deals[dealIndex];
        if (sender != d.partyA) revert NotPartyA();
        if (d.status != WAITING_CONFIRM) revert InvalidStatus();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();

        uint96 amt = d.amount;
        d.amount = 0;
        d.status = COMPLETED;

        _emitStatusChanged(dealIndex, COMPLETED);
        _emitPhaseChanged(dealIndex, 3); // → Success

        if (!IERC20(feeToken).transfer(d.partyB, amt)) revert TransferFailed();
    }

    // ===================== 取消（WAITING_ACCEPT → CANCELLED） =====================

    /// @notice A 取消 B 尚未接受的交易（WAITING_ACCEPT + 已超时）
    function cancelDeal(uint256 dealIndex)
        external
        nonReentrant
        onlyA(dealIndex)
        atStatus(dealIndex, WAITING_ACCEPT)
    {
        if (!_isStageTimedOut(dealIndex)) revert NotTimedOut();

        Deal storage d = deals[dealIndex];
        uint96 amt = d.amount + PROTOCOL_FEE;
        d.amount = 0;
        d.status = CANCELLED;

        _emitPhaseChanged(dealIndex, 5); // → Cancelled
        _emitStatusChanged(dealIndex, CANCELLED);

        if (amt > 0) {
            if (!IERC20(feeToken).transfer(d.partyA, amt)) revert TransferFailed();
        }
    }

    // ===================== 验证 =====================

    /// @notice Trader 触发验证（调用者通过 approve 支付验证费）
    function requestVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        nonReentrant
        override
    {
        _requestVerificationCore(msg.sender, dealIndex, verificationIndex);
    }

    /// @notice Trader 触发验证（gasless BySig 版本）
    function requestVerificationBySig(uint256 dealIndex, uint256 verificationIndex, PermitData calldata permit, MetaTxProof calldata proof)
        external
        nonReentrant
    {
        bytes32 structHash = keccak256(abi.encode(
            _REQUEST_VERIFICATION_TYPEHASH,
            dealIndex, verificationIndex,
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        _executePermit(permit, proof.signer);
        _requestVerificationCore(proof.signer, dealIndex, verificationIndex);
    }

    function _requestVerificationCore(address sender, uint256 dealIndex, uint256 verificationIndex) internal {
        if (verificationIndex != 0) revert InvalidVerificationIndex();

        Deal storage d = deals[dealIndex];
        if (d.status != WAITING_CONFIRM) revert InvalidStatus();
        if (sender != d.partyA && sender != d.partyB) revert NotAorB();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();

        uint96 fee = d.verifierFee;
        address verifier = d.verifier;

        // CEI：先改状态
        d.status = VERIFYING;
        d.isRequesterA = (sender == d.partyA);
        d.verificationTimestamp = uint48(block.timestamp);

        emit VerificationRequested(dealIndex, verificationIndex, verifier);

        if (!IERC20(feeToken).transferFrom(sender, address(this), fee)) revert TransferFailed();
    }

    /// @notice Verifier 提交验证结果
    /// @dev result > 0 → 通过，付款给 B
    ///      result < 0 → 失败，B 违约
    ///      result == 0 → 不确定，进入协商
    function onVerificationResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason) external nonReentrant override onlySlot0(verificationIndex) {
        Deal storage d = deals[dealIndex];

        if (msg.sender != d.verifier) revert NotVerifier();
        if (d.status != VERIFYING) revert InvalidStatus();
        if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) revert AlreadyTimedOut();

        // 清除验证时间戳
        d.verificationTimestamp = 0;

        uint96 vFee = d.verifierFee;
        uint96 transferToB = 0;

        if (result > 0) {
            transferToB = d.amount;
            d.amount = 0;
            d.status = COMPLETED;
        } else if (result < 0) {
            d.status = VIOLATED;
            d.violator = d.partyB;
        } else {
            d.status = SETTLING;
            d.stageTimestamp = uint48(block.timestamp);
        }

        // --- 事件 ---
        emit VerificationReceived(dealIndex, verificationIndex, msg.sender, result);

        if (result > 0) {
            _emitStatusChanged(dealIndex, COMPLETED);
            _emitPhaseChanged(dealIndex, 3); // → Success
        } else if (result < 0) {
            _emitViolated(dealIndex, d.partyB, reason);
            _emitStatusChanged(dealIndex, VIOLATED);
            _emitPhaseChanged(dealIndex, 4); // → Failed
        } else {
            _emitStatusChanged(dealIndex, SETTLING);
        }

        // --- 交互：所有转账最后执行 ---
        if (vFee > 0) {
            if (result == 0) {
                // inconclusive — 验证者未完成工作，退还 verifierFee 给请求方
                address requester = d.isRequesterA ? d.partyA : d.partyB;
                if (!IERC20(feeToken).transfer(requester, vFee)) revert TransferFailed();
            } else {
                if (!IERC20(feeToken).transfer(msg.sender, vFee)) revert TransferFailed();
            }
        }
        if (transferToB > 0) {
            if (!IERC20(feeToken).transfer(d.partyB, transferToB)) revert TransferFailed();
        }
    }

    // ===================== 验证重置 =====================

    /// @notice Verifier 超时后重置验证，退还验证费，进入协商
    function resetVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        nonReentrant
        atStatus(dealIndex, VERIFYING)
        onlySlot0(verificationIndex)
    {
        Deal storage d = deals[dealIndex];
        address sender = msg.sender;
        if (sender != d.partyA && sender != d.partyB) revert NotAorB();
        if (block.timestamp <= uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT)
            revert VerificationNotTimedOut();

        address requester = d.isRequesterA ? d.partyA : d.partyB;
        uint96 vFee = d.verifierFee;

        // CEI：先改状态
        d.verificationTimestamp = 0;
        d.status = SETTLING;
        d.stageTimestamp = uint48(block.timestamp);

        _emitViolated(dealIndex, d.verifier, "verifier timeout");
        _emitStatusChanged(dealIndex, SETTLING);

        if (vFee > 0) {
            if (!IERC20(feeToken).transfer(requester, vFee)) revert TransferFailed();
        }
    }

    // ===================== 协商 =====================

    /// @notice 提出协商方案：amountToA 是给 A 的金额（剩余归 B）
    /// @dev 双提案模式：A/B 各自维护独立提案，互不覆盖。12h 后禁止新提案。
    ///      每次提案版本号 +1，确认时需附带版本号防止前端运行覆盖。
    function proposeSettlement(uint256 dealIndex, uint96 amountToA)
        external
        nonReentrant
    {
        _proposeSettlementCore(msg.sender, dealIndex, amountToA);
    }

    /// @notice 提出协商方案（gasless BySig 版本）
    function proposeSettlementBySig(uint256 dealIndex, uint96 amountToA, MetaTxProof calldata proof)
        external
        nonReentrant
    {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_SETTLEMENT_TYPEHASH,
            dealIndex, amountToA,
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        _proposeSettlementCore(proof.signer, dealIndex, amountToA);
    }

    function _proposeSettlementCore(address sender, uint256 dealIndex, uint96 amountToA) internal {
        Deal storage d = deals[dealIndex];
        if (d.status != SETTLING) revert InvalidStatus();
        if (sender != d.partyA && sender != d.partyB) revert NotAorB();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();
        if (amountToA > d.amount) revert InvalidSettlement();

        uint256 newVersion;
        if (sender == d.partyA) {
            Settlement storage s = settlementByA[dealIndex];
            s.proposer = sender;
            s.amountToA = amountToA;
            s.version += 1;
            newVersion = s.version;
        } else {
            Settlement storage s = settlementByB[dealIndex];
            s.proposer = sender;
            s.amountToA = amountToA;
            s.version += 1;
            newVersion = s.version;
        }

        emit SettlementProposed(dealIndex, sender, amountToA, newVersion);
    }

    /// @notice 确认对方的协商提案
    /// @dev 12h 内正常确认；12h~13h grace period 内仍可确认已有提案（但不可提新案）；13h 后封锁。
    /// @param expectedVersion 期望的提案版本号，防止前端运行覆盖
    function confirmSettlement(uint256 dealIndex, uint256 expectedVersion)
        external
        nonReentrant
    {
        _confirmSettlementCore(msg.sender, dealIndex, expectedVersion);
    }

    /// @notice 确认对方的协商提案（gasless BySig 版本）
    function confirmSettlementBySig(uint256 dealIndex, uint256 expectedVersion, MetaTxProof calldata proof)
        external
        nonReentrant
    {
        bytes32 structHash = keccak256(abi.encode(
            _CONFIRM_SETTLEMENT_TYPEHASH,
            dealIndex, expectedVersion,
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        _confirmSettlementCore(proof.signer, dealIndex, expectedVersion);
    }

    function _confirmSettlementCore(address sender, uint256 dealIndex, uint256 expectedVersion) internal {
        Deal storage d = deals[dealIndex];
        if (d.status != SETTLING) revert InvalidStatus();
        if (sender != d.partyA && sender != d.partyB) revert NotAorB();

        // 获取对方的提案
        Settlement storage stl = (sender == d.partyA) ? settlementByB[dealIndex] : settlementByA[dealIndex];
        if (stl.proposer == address(0)) revert InvalidSettlement();
        if (stl.version != expectedVersion) revert VersionMismatch();

        // 超时检查：12h 内 OK；12h~13h grace OK；13h 后封锁
        uint256 graceDeadline = uint256(d.stageTimestamp) + SETTLING_TIMEOUT + CONFIRM_GRACE_PERIOD;
        if (block.timestamp > graceDeadline) revert AlreadyTimedOut();

        uint96 toA = stl.amountToA;
        uint96 toB = d.amount - toA;
        d.amount = 0;
        d.status = COMPLETED;

        delete settlementByA[dealIndex];
        delete settlementByB[dealIndex];

        _emitStatusChanged(dealIndex, COMPLETED);
        _emitPhaseChanged(dealIndex, 3); // → Success

        if (toA > 0) {
            if (!IERC20(feeToken).transfer(d.partyA, toA)) revert TransferFailed();
        }
        if (toB > 0) {
            if (!IERC20(feeToken).transfer(d.partyB, toB)) revert TransferFailed();
        }
    }

    /// @notice 协商超时，资金没收到 FeeCollector
    /// @dev 有提案时需等 grace period (13h) 过后；无提案时 12h 后即可触发。
    function triggerSettlementTimeout(uint256 dealIndex)
        external
        nonReentrant
        atStatus(dealIndex, SETTLING)
    {
        Deal storage d = deals[dealIndex];
        address sender = msg.sender;
        if (sender != d.partyA && sender != d.partyB) revert NotAorB();

        uint256 settlingDeadline = uint256(d.stageTimestamp) + SETTLING_TIMEOUT;
        bool hasProposal = settlementByA[dealIndex].proposer != address(0)
                        || settlementByB[dealIndex].proposer != address(0);

        if (hasProposal) {
            if (block.timestamp <= settlingDeadline + CONFIRM_GRACE_PERIOD) revert SettlementNotTimedOut();
        } else {
            if (block.timestamp <= settlingDeadline) revert SettlementNotTimedOut();
        }

        uint96 seized = d.amount;
        d.amount = 0;
        d.status = FORFEITED;
        delete settlementByA[dealIndex];
        delete settlementByB[dealIndex];

        _emitStatusChanged(dealIndex, FORFEITED);
        _emitPhaseChanged(dealIndex, 4); // → Failed

        if (seized > 0) {
            if (!IERC20(feeToken).transfer(FEE_COLLECTOR, seized)) revert TransferFailed();
        }
    }

    // ===================== 超时 =====================

    /// @notice 触发当前阶段的超时处理
    /// @dev WAITING_CLAIM 超时：B 未 claimDone → B 违约
    ///      WAITING_CONFIRM 超时：A 未确认 → 自动付款给 B
    function triggerTimeout(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        if (!_isStageTimedOut(dealIndex)) revert NotTimedOut();

        uint8 s = d.status;

        if (s == WAITING_CLAIM) {
            // B 未 claimDone → B 违约
            if (msg.sender != d.partyA) revert NotPartyA();
            d.status = VIOLATED;
            d.violator = d.partyB;
            _emitViolated(dealIndex, d.partyB, "claim timeout");
            _emitStatusChanged(dealIndex, VIOLATED);
            _emitPhaseChanged(dealIndex, 4); // → Failed

        } else if (s == WAITING_CONFIRM) {
            // A 未确认 → 自动付款给 B
            if (msg.sender != d.partyB) revert NotPartyB();
            uint96 amt = d.amount;
            d.amount = 0;
            d.status = COMPLETED;
            _emitStatusChanged(dealIndex, COMPLETED);
            _emitPhaseChanged(dealIndex, 3); // → Success
            if (!IERC20(feeToken).transfer(d.partyB, amt)) revert TransferFailed();

        } else {
            revert InvalidStatus();
        }
    }

    /// @notice 违约后提取资金
    function withdraw(uint256 dealIndex) external nonReentrant atStatus(dealIndex, VIOLATED) {
        Deal storage d = deals[dealIndex];
        address sender = msg.sender;
        if (sender != d.partyA && sender != d.partyB) revert NotAorB();
        if (sender == d.violator) revert ViolatorCannot();
        if (d.amount == 0) revert NoFunds();

        uint96 amt = d.amount;
        d.amount = 0;

        if (!IERC20(feeToken).transfer(sender, amt)) revert TransferFailed();
    }

    // ===================== 内部辅助函数 =====================

    function _verifyVerifierSignature(
        address verifier,
        string calldata tweet_id,
        uint64 quoterUserId,
        uint96 fee,
        uint256 deadline,
        bytes calldata sig
    ) internal view {
        address verifierSpec = IVerifier(verifier).spec();
        if (verifierSpec != REQUIRED_SPEC) revert InvalidSpecAddress();
        address recovered = XQuoteVerifierSpec(verifierSpec).check(verifier, tweet_id, quoterUserId, uint256(fee), deadline, sig);
        if (recovered != IVerifier(verifier).signer()) revert InvalidVerifierSignature();
    }

    /// @dev 检查当前阶段是否已超时（基于 stageTimestamp）
    function _isStageTimedOut(uint256 dealIndex) internal view returns (bool) {
        Deal storage d = deals[dealIndex];
        uint256 timeout = d.status == SETTLING ? SETTLING_TIMEOUT : STAGE_TIMEOUT;
        return block.timestamp > uint256(d.stageTimestamp) + timeout;
    }

    // ===================== 查询函数 =====================

    /// @notice 获取当前阶段的剩余时间（秒）
    function timeRemaining(uint256 dealIndex) external view returns (uint256) {
        Deal storage d = deals[dealIndex];
        uint256 deadline_;
        if (d.status == VERIFYING && d.verificationTimestamp > 0) {
            deadline_ = uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT;
        } else if (d.status == SETTLING) {
            bool hasProposal = settlementByA[dealIndex].proposer != address(0)
                            || settlementByB[dealIndex].proposer != address(0);
            deadline_ = uint256(d.stageTimestamp) + SETTLING_TIMEOUT + (hasProposal ? CONFIRM_GRACE_PERIOD : 0);
        } else {
            deadline_ = uint256(d.stageTimestamp) + STAGE_TIMEOUT;
        }
        if (block.timestamp >= deadline_) return 0;
        return deadline_ - block.timestamp;
    }

    /// @notice 检查验证是否已超时
    function isVerificationTimedOut(uint256 dealIndex) external view returns (bool) {
        Deal storage d = deals[dealIndex];
        if (d.status != VERIFYING) return false;
        return block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT;
    }

    /// @notice 获取双方协商提案信息
    function settlement(uint256 dealIndex) external view returns (
        uint96  proposalByA_amountToA,
        uint96  proposalByB_amountToA,
        bool    hasProposalA,
        bool    hasProposalB,
        uint256 settlementVersionA,
        uint256 settlementVersionB
    ) {
        Settlement storage stlA = settlementByA[dealIndex];
        Settlement storage stlB = settlementByB[dealIndex];
        return (
            stlA.amountToA,
            stlB.amountToA,
            stlA.proposer != address(0),
            stlB.proposer != address(0),
            stlA.version,
            stlB.version
        );
    }

    /// @notice 检查交易阶段是否已超时
    function isTimedOut(uint256 dealIndex) external view returns (bool) {
        return _isStageTimedOut(dealIndex);
    }

    // ===================== 标准身份标识 =====================

    function name() external pure override returns (string memory) {
        return "X Quote Tweet Deal";
    }

    function description() external pure override returns (string memory) {
        return "Pay USDC to get a tweet quoted on X (Twitter). 2-party USDC settlement. Quoter requires Twitter binding.";
    }

    function tags() external pure override returns (string[] memory) {
        string[] memory t = new string[](5);
        t[0] = "x";
        t[1] = "quote";
        t[2] = "twitter";
        t[3] = "kol";
        t[4] = "tweet";
        return t;
    }

    function version() external pure override returns (string memory) {
        return "3.0";
    }

    function protocolFee() external view returns (uint96) {
        return PROTOCOL_FEE;
    }

    function protocolFeePolicy() external pure override returns (string memory) {
        return
            "Fixed protocol fee per deal. "
            "A pays grossAmount = reward + protocolFee on createDeal. "
            "Fee is sent to FeeCollector when B calls accept; fully refunded if cancelled before accept. "
            "Query exact value via protocolFee().";
    }

    // ===================== 验证查询 =====================

    function requiredSpecs() external view override returns (address[] memory) {
        address[] memory specs = new address[](1);
        specs[0] = REQUIRED_SPEC;
        return specs;
    }

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

        specParams = abi.encode(d.tweet_id, d.quoter_user_id, d.quote_tweet_id);

        return (d.verifier, uint256(d.verifierFee), d.signatureDeadline, d.verifierSignature, specParams);
    }

    // ===================== 操作指南 =====================

    function instruction() external view override returns (string memory) {
        return
            "# X Quote Tweet Deal\n\n"
            "Pay USDC to get a tweet quoted on X. 2-party (payer + quoter). On-chain verifier for auto-completion or manual confirm. 30min stage timeout, settlement on dispute.\n\n"
            "- **A (Initiator)**: Specifies a tweet + deposits USDC reward\n"
            "- **B (Executor)**: Quotes the tweet on X\n"
            "- After A manually confirms or verifier auto-verifies, B receives the reward\n\n"
            "| Item | Value |\n"
            "|----|----|\n"
            "| Token | USDC (decimals=6), address via `feeToken()` |\n"
            "| Amount | Raw value x10^6, e.g. 1.5 USDC = `1500000` |\n\n"
            "## Price Negotiation\n\n"
            "Before creating a deal, A and B negotiate B's reward (net amount):\n\n"
            "- **A (Offer)**: Evaluate based on B's follower count, engagement rate, etc.\n"
            "- **B (Evaluate)**: Judge whether the offer is fair; counter-offer if not.\n"
            "- Either party may walk away if the price is unacceptable.\n\n"
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
            "| quoterUserId | uint64 | B's Twitter immutable user_id |\n"
            "| bindingSig | bytes | B's Twitter binding signature (proves B's X account is bound to their wallet address) |\n\n"
            "**Prerequisites**:\n"
            "1. B must complete Twitter binding before createDeal() -- bind their X account to their wallet address and obtain the binding signature via twitter-binding-sig\n"
            "2. B must ensure they have NOT quoted the target tweet before the deal is created. If B has already quoted it, the verifier will reject the task and B will not receive the reward\n"
            "3. A should maintain their own record of which quoters have already quoted the target tweet, to prevent the same quoter from creating duplicate deals for the same tweet\n"
            "4. Both parties have agreed on B's reward and tweet_id. A calls `protocolFee()` to get the protocol fee, grossAmount = reward + protocol fee\n"
            "5. USDC `approve(contract address, reward + protocol fee + verification fee)`, i.e., grossAmount + verifierFee\n"
            "6. Obtain verifier signature via `request_sign` (sig + fee)\n\n"
            "> On creation, `grossAmount` is transferred to the contract in full; the protocol fee is only sent to `FeeCollector` after B calls `accept`. If B does not accept and the deal is cancelled, both protocol fee and reward are refunded to A.\n\n"
            "## dealStatus Action Guide\n\n"
            "`dealStatus(dealIndex)` returns the current status (unified, same for all callers). Refer to the table below for actions:\n\n"
            "| Code | Status | A's Action | B's Action |\n"
            "|----|------|------|------|\n"
            "| 0 | WaitingAccept | Wait for B | `accept(dealIndex)` |\n"
            "| 1 | AcceptTimedOut | `cancelDeal(dealIndex)` | -- |\n"
            "| 2 | WaitingClaim | Wait for B | Quote tweet, then `claimDone(dealIndex, quote_tweet_id)` |\n"
            "| 3 | ClaimTimedOut | `triggerTimeout(dealIndex)` | -- |\n"
            "| 4 | WaitingConfirm | `confirmAndPay(dealIndex)` or `requestVerification(dealIndex, 0)` | Wait for A |\n"
            "| 5 | ConfirmTimedOut | -- | `triggerTimeout(dealIndex)` |\n"
            "| 6 | Verifying | Wait | Wait |\n"
            "| 7 | VerifierTimedOut | `resetVerification(dealIndex, 0)` | `resetVerification(dealIndex, 0)` |\n"
            "| 8 | Settling | `proposeSettlement(dealIndex, amountToA)` | `proposeSettlement(dealIndex, amountToA)` |\n"
            "| 9 | SettlementProposed | `confirmSettlement(dealIndex, expectedVersion)` to accept counterparty's proposal, or update own proposal | `confirmSettlement(dealIndex, expectedVersion)` to accept counterparty's proposal, or update own proposal |\n"
            "| 10 | SettlementTimedOut | `triggerSettlementTimeout(dealIndex)` | `triggerSettlementTimeout(dealIndex)` |\n"
            "| 11 | Completed | -- | -- |\n"
            "| 12 | Violated | Non-violator: `withdraw(dealIndex)` | Non-violator: `withdraw(dealIndex)` |\n"
            "| 13 | Cancelled | -- | -- |\n"
            "| 14 | Forfeited | -- (funds seized to protocol) | -- (funds seized to protocol) |\n"
            "| 255 | NotFound | Deal does not exist | Deal does not exist |\n\n"
            "> **Timeouts**: 30 minutes per stage (Settling: 12 hours). Use `timeRemaining(dealIndex)` to query remaining seconds.\n\n"
            "> **Settlement timeout (code 10)**: After 12 hours, new proposals are blocked. If any proposal exists, a 1-hour grace period allows `confirmSettlement` only. After the grace period (or immediately if no proposals), `triggerSettlementTimeout` forfeits all funds to the protocol.\n\n"
            "> **Verification flow (code 4)**:\n"
            "> 1. `requestVerification(dealIndex, 0)`\n"
            "> 2. **Must** call `notify_verifier(verifier_address, dealContract, dealIndex, verificationIndex)` to notify the verifier\n"
            "> 3. Passed: auto-payment to B; failed: B is in breach. Verification fee is non-refundable.\n\n"
            "> **Settlement semantics (code 8/9)**: Each party maintains their own proposal independently. In `proposeSettlement(dealIndex, amountToA)`, amountToA is **the amount A receives** (x10^6); the remainder goes to B. Call `settlement(dealIndex)` to query proposals and their version numbers. `confirmSettlement(dealIndex, expectedVersion)` accepts the counterparty's proposal; pass the counterparty's version from `settlement()` as expectedVersion.\n\n"
            "## Gasless Relay\n\n"
            "All primary write operations optionally support gasless relay via `BySig` variants (EIP-712 meta-transaction). "
            "The user signs, a relayer submits on-chain and pays gas.\n";
    }

    // ===================== 状态查询 =====================

    /// @notice 平台级统一交易阶段
    /// @dev 0=NotFound, 1=Pending, 2=Active, 3=Success, 4=Failed, 5=Cancelled
    function phase(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.partyA == address(0)) return 0; // NotFound

        uint8 s = d.status;
        if (s == WAITING_ACCEPT) return 1;   // Pending
        if (s == COMPLETED) return 3;         // Success
        if (s == VIOLATED) return 4;          // Failed
        if (s == FORFEITED) return 4;         // Failed
        if (s == CANCELLED) return 5;         // Cancelled
        return 2; // Active（WAITING_CLAIM, WAITING_CONFIRM, VERIFYING, SETTLING）
    }

    /// @notice 统一业务状态码 — 不依赖 msg.sender，任何人调用结果一致
    /// @dev 存储的基础值叠加运行时条件（超时、是否有提案）派生出完整状态码 0-14, 255
    function dealStatus(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.partyA == address(0)) return NOT_FOUND;

        uint8 s = d.status;

        // WAITING_ACCEPT (0) → 可能超时 (1)
        if (s == WAITING_ACCEPT) {
            return _isStageTimedOut(dealIndex) ? ACCEPT_TIMED_OUT : WAITING_ACCEPT;
        }

        // WAITING_CLAIM (2) → 可能超时 (3)
        if (s == WAITING_CLAIM) {
            return _isStageTimedOut(dealIndex) ? CLAIM_TIMED_OUT : WAITING_CLAIM;
        }

        // WAITING_CONFIRM (4) → 可能超时 (5)
        if (s == WAITING_CONFIRM) {
            return _isStageTimedOut(dealIndex) ? CONFIRM_TIMED_OUT : WAITING_CONFIRM;
        }

        // VERIFYING (6) → 可能 Verifier 超时 (7)
        if (s == VERIFYING) {
            if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) {
                return VERIFIER_TIMED_OUT;
            }
            return VERIFYING;
        }

        // SETTLING (8) → 可能有提案 (9) 或超时 (10)
        if (s == SETTLING) {
            bool hasProposal = settlementByA[dealIndex].proposer != address(0)
                            || settlementByB[dealIndex].proposer != address(0);
            uint256 settlingDeadline = uint256(d.stageTimestamp) + SETTLING_TIMEOUT;
            if (hasProposal) {
                if (block.timestamp > settlingDeadline + CONFIRM_GRACE_PERIOD) return SETTLEMENT_TIMED_OUT;
            } else {
                if (block.timestamp > settlingDeadline) return SETTLEMENT_TIMED_OUT;
            }
            if (hasProposal) return SETTLEMENT_PROPOSED;
            return SETTLING;
        }

        // 终态：COMPLETED (11), VIOLATED (12), CANCELLED (13), FORFEITED (14)
        return s;
    }

    /// @notice 指定索引的交易是否存在
    function dealExists(uint256 dealIndex) external view override returns (bool) {
        return deals[dealIndex].partyA != address(0);
    }
}
