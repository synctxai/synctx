// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealBase.sol";
import "./IVerifier.sol";
import "./XFollowVerifierSpec.sol";
import "./IERC20.sol";
import "./MetaTxMixin.sol";
import "./BindingAttestation.sol";


/// @title XFollowCampaign - X 付费关注 Campaign 子合约
/// @notice 由 XFollowFactory 通过 EIP-1167 clone 创建。每个实例 = 一个 campaign。
///         A 存入预算，任何通过 Binding Attestation 认证的用户可关注后领取固定奖励。
///         每个 B 的 claim() 创建一个新的 dealIndex。全自动，无需协商。
/// @dev 生命周期：OPEN → CLOSED
///      无 constructor — 所有状态通过 initialize() 一次性设置（clone 兼容）。
contract XFollowCampaign is DealBase, MetaTxMixin("", "") {

    /// @dev Lock implementation against initialize() — clones are unaffected.
    constructor() {
        _initialized = true;
    }

    // ===================== 错误 =====================

    error NotPartyA();
    error NotVerifier();
    error InvalidStatus();
    error InvalidParams();
    error TransferFailed();
    error VerifierNotContract();
    error InvalidVerifierSignature();
    error SignatureExpired();
    error InvalidSpecAddress();
    error CampaignNotOpen();
    error BudgetExhausted();
    error AlreadyClaimed();
    error MaxFailures();
    error InvalidBindingSignature();
    error PendingClaim();
    error NotClosed();
    error PendingClaims();
    error NoFunds();
    error VerificationNotTimedOut();
    error VerificationTimedOut();
    error InvalidVerificationIndex();
    error InsufficientBudget();
    error AlreadyInitialized();
    error Reentrancy();

    // ===================== 事件 =====================

    /// @notice Verifier 超时事件，供平台索引 verifier 可靠性
    event VerifierTimeout(uint256 indexed dealIndex, address indexed verifier);

    // ===================== dealStatus 常量（per-claim） =====================
    //
    //   存储基础值            dealStatus 派生值
    //   ─────────────         ──────────────────
    //   VERIFYING        (0)  → VERIFIER_TIMED_OUT (1)
    //   COMPLETED        (2)
    //   REJECTED         (3)
    //   TIMED_OUT        (4)
    //   INCONCLUSIVE     (5)
    //   NOT_FOUND       (255)

    uint8 constant VERIFYING            = 0;
    uint8 constant VERIFIER_TIMED_OUT   = 1;
    uint8 constant COMPLETED            = 2;
    uint8 constant REJECTED             = 3;
    uint8 constant TIMED_OUT            = 4;
    uint8 constant INCONCLUSIVE         = 5;
    uint8 constant NOT_FOUND            = 255;

    // ===================== campaignStatus 常量 =====================

    uint8 constant OPEN                 = 1;
    uint8 constant CLOSED               = 2;

    // ===================== 类型 =====================

    struct Claim {
        address claimer;             // B 的地址
        uint48  timestamp;           // claim 创建时间
        uint8   status;              // VERIFYING / COMPLETED / REJECTED / TIMED_OUT / INCONCLUSIVE
        uint64  follower_user_id;    // claim 时通过 Binding Attestation 验证
    }

    // ===================== 常量 =====================

    uint256 public constant VERIFICATION_TIMEOUT = 30 minutes;
    uint8 public constant MAX_FAILURES = 3;

    // ===================== 初始化守卫 & 重入锁 =====================

    bool private _initialized;
    uint256 private _lock = 1;

    // ===================== Config（由 factory 在 initialize 时传入） =====================

    address public feeToken;
    address public feeCollector;
    uint96  public protocolFee;
    address public requiredSpec;
    BindingAttestation public bindingAttestation;

    // ===================== Campaign 存储 =====================

    address public partyA;
    uint8   public campaignStatus;       // OPEN / CLOSED
    address public verifier;
    uint96  public rewardPerFollow;
    uint96  public verifierFee;
    uint48  public deadline;
    uint96  public budget;
    uint32  public pendingClaims;
    uint32  public completedClaims;
    uint256 public signatureDeadline;
    uint64  public target_user_id;
    bytes   public verifierSignature;

    /// @notice Verifier 超时次数（链上信用信号）
    uint32  public verifierTimeoutCount;

    // ===================== Per-Claim 存储 =====================

    mapping(uint256 => Claim) internal claims;
    mapping(address => bool)  public claimedAddress;
    mapping(uint64  => uint8) public claimedUserId;          // 0=未领取 1=验证中 2=已领取
    mapping(address => uint8) public failCount;
    mapping(address => uint256) internal pendingClaimIndex;  // B → 当前 pending 的 dealIndex

    // ===================== BySig TYPEHASH 常量 =====================

    bytes32 private constant _CLAIM_TYPEHASH = keccak256(
        "ClaimBySig(uint64 userId,bytes32 bindingSigHash,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    // ===================== 修饰器 =====================

    modifier onlyA() {
        if (msg.sender != partyA) revert NotPartyA();
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

    // ===================== 初始化（替代 constructor，clone 兼容） =====================

    /// @notice 由 XFollowFactory 在 clone 后原子调用，一次性初始化所有参数
    function initialize(
        address feeToken_,
        address feeCollector_,
        uint96  protocolFee_,
        address requiredSpec_,
        address bindingAttestation_,
        address partyA_,
        address verifier_,
        uint96  rewardPerFollow_,
        uint96  verifierFee_,
        uint48  deadline_,
        uint96  grossAmount_,
        uint64  target_user_id_,
        uint256 sigDeadline_,
        bytes calldata sig_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _lock = 1; // clone storage starts at 0; set to 1 for 1/2 reentrancy pattern

        // MetaTxMixin 初始化（clone 路径）
        _initMetaTxDomain("XFollowCampaign", "1");

        // Config
        feeToken = feeToken_;
        feeCollector = feeCollector_;
        protocolFee = protocolFee_;
        requiredSpec = requiredSpec_;
        bindingAttestation = BindingAttestation(bindingAttestation_);

        // Campaign 参数验证
        if (rewardPerFollow_ == 0) revert InvalidParams();
        if (deadline_ <= block.timestamp) revert InvalidParams();
        if (verifier_ == address(0)) revert InvalidParams();
        if (partyA_ == verifier_) revert InvalidParams();
        if (verifier_.code.length == 0) revert VerifierNotContract();
        if (sig_.length == 0) revert InvalidVerifierSignature();
        if (sigDeadline_ < deadline_) revert SignatureExpired();
        if (grossAmount_ < rewardPerFollow_ + verifierFee_ + protocolFee_) revert InsufficientBudget();
        if (target_user_id_ == 0) revert InvalidParams();

        // 验证 Verifier 签名
        _verifyVerifierSignature(verifier_, target_user_id_, verifierFee_, sigDeadline_, sig_);

        // 设置 campaign（USDC 已由 factory transferFrom 到本合约）
        partyA = partyA_;
        campaignStatus = OPEN;
        verifier = verifier_;
        rewardPerFollow = rewardPerFollow_;
        verifierFee = verifierFee_;
        deadline = deadline_;
        budget = grossAmount_;
        signatureDeadline = sigDeadline_;
        target_user_id = target_user_id_;
        verifierSignature = sig_;
    }

    // ===================== Claim（每个 claim = 一个 dealIndex） =====================

    /// @notice B 领取关注奖励。提交 Binding Attestation 证明身份。
    ///         claimedUserId 状态：0=可领取，1=验证中（锁定），2=已成功领取（永久锁定）。
    ///         验证失败/inconclusive 自动回退为 0；超时需先调 resetVerification() 回退后方可重试。
    /// @param userId B 的 Twitter immutable user_id
    /// @param bindingSig Platform 签发的绑定证明签名
    function claim(uint64 userId, bytes calldata bindingSig) external nonReentrant returns (uint256 dealIndex) {
        return _claimCore(msg.sender, userId, bindingSig);
    }

    /// @notice B 领取关注奖励（gasless BySig 版本）
    function claimBySig(uint64 userId, bytes calldata bindingSig, MetaTxProof calldata proof)
        external nonReentrant returns (uint256 dealIndex)
    {
        bytes32 structHash = keccak256(abi.encode(
            _CLAIM_TYPEHASH,
            userId, keccak256(bindingSig),
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        return _claimCore(proof.signer, userId, bindingSig);
    }

    function _claimCore(address sender, uint64 userId, bytes calldata bindingSig) internal returns (uint256 dealIndex) {
        // 检查并可能触发 auto-close
        _checkAndClose();
        if (campaignStatus != OPEN) revert CampaignNotOpen();

        if (claimedAddress[sender]) revert AlreadyClaimed();
        if (claimedUserId[userId] != 0) revert AlreadyClaimed();
        if (failCount[sender] >= MAX_FAILURES) revert MaxFailures();

        // 检查是否有 pending claim
        if (_hasPendingClaim(sender)) revert PendingClaim();

        // 验证 Binding Attestation
        if (!bindingAttestation.verify(sender, userId, bindingSig)) revert InvalidBindingSignature();
        uint64 followerUserId = userId;

        uint96 cost = _claimCost();
        if (budget < cost) {
            // 预算不足，auto-close
            if (pendingClaims == 0) {
                campaignStatus = CLOSED;
            }
            revert BudgetExhausted();
        }

        // 锁定费用
        budget -= cost;

        // 创建 claim（= dealIndex）
        {
            address[] memory traders = new address[](1);
            traders[0] = sender;
            address[] memory verifiers = new address[](1);
            verifiers[0] = verifier;
            dealIndex = _recordStart(traders, verifiers);
        }

        claims[dealIndex] = Claim({
            claimer: sender,
            timestamp: uint48(block.timestamp),
            status: VERIFYING,
            follower_user_id: followerUserId
        });
        pendingClaimIndex[sender] = dealIndex;
        claimedUserId[followerUserId] = 1;
        pendingClaims++;

        _emitStatusChanged(dealIndex, VERIFYING);
        _emitPhaseChanged(dealIndex, 2); // → Active

        emit VerificationRequested(dealIndex, 0, verifier);
    }

    // ===================== 验证结果回调 =====================

    /// @notice Verifier 提交验证结果
    function onVerificationResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata /* reason */)
        external override onlySlot0(verificationIndex) nonReentrant
    {
        if (msg.sender != verifier) revert NotVerifier();
        Claim storage c = claims[dealIndex];
        if (c.status != VERIFYING) revert InvalidStatus();
        if (_isVerificationTimedOut(c)) revert VerificationTimedOut();

        uint96 reward = rewardPerFollow;
        uint96 vFee = verifierFee;
        uint96 pFee = protocolFee;
        address claimer = c.claimer;

        pendingClaims--;
        delete pendingClaimIndex[claimer];

        emit VerificationReceived(dealIndex, verificationIndex, msg.sender, result);

        if (result > 0) {
            // 通过：付款给 B
            c.status = COMPLETED;
            claimedAddress[claimer] = true;
            claimedUserId[c.follower_user_id] = 2;
            completedClaims++;

            _emitStatusChanged(dealIndex, COMPLETED);
            _emitPhaseChanged(dealIndex, 3); // → Success

            if (!IERC20(feeToken).transfer(claimer, reward)) revert TransferFailed();
            if (vFee > 0) {
                if (!IERC20(feeToken).transfer(msg.sender, vFee)) revert TransferFailed();
            }
            if (!IERC20(feeToken).transfer(feeCollector, pFee)) revert TransferFailed();

        } else if (result < 0) {
            // 失败：reward + protocolFee 退回预算，仅 verifierFee 付出，B 违约
            c.status = REJECTED;
            failCount[claimer]++;
            claimedUserId[c.follower_user_id] = 0;
            budget += reward + pFee;

            _emitViolated(dealIndex, claimer, "follow not detected");
            _emitStatusChanged(dealIndex, REJECTED);
            _emitPhaseChanged(dealIndex, 4); // → Failed

            if (vFee > 0) {
                if (!IERC20(feeToken).transfer(msg.sender, vFee)) revert TransferFailed();
            }

        } else {
            // 不确定：全额退回预算，不扣费
            c.status = INCONCLUSIVE;
            claimedUserId[c.follower_user_id] = 0;
            budget += reward + vFee + pFee;

            _emitStatusChanged(dealIndex, INCONCLUSIVE);
            _emitPhaseChanged(dealIndex, 4); // → Failed
        }

        // 检查是否应 auto-close
        _checkAndClose();
    }

    // ===================== 验证超时重置 =====================

    /// @notice Verifier 超时后重置 claim，全额退回预算。
    ///         任何人均可调用（permissionless cleanup）。
    ///         重置后解锁 claimedUserId 和 pendingClaimIndex，B 可重新 claim()。
    ///         验证失败(result<0) 和 inconclusive(result==0) 由 onVerificationResult 自动清理，无需手动 reset。
    function resetVerification(uint256 dealIndex, uint256 verificationIndex)
        external onlySlot0(verificationIndex) nonReentrant
    {
        Claim storage c = claims[dealIndex];
        if (c.status != VERIFYING) revert InvalidStatus();
        if (!_isVerificationTimedOut(c)) revert VerificationNotTimedOut();

        c.status = TIMED_OUT;
        pendingClaims--;
        delete pendingClaimIndex[c.claimer];
        claimedUserId[c.follower_user_id] = 0;
        budget += _claimCost();
        verifierTimeoutCount++;

        emit VerifierTimeout(dealIndex, verifier);
        _emitViolated(dealIndex, verifier, "verifier timeout");
        _emitStatusChanged(dealIndex, TIMED_OUT);
        _emitPhaseChanged(dealIndex, 4); // → Failed

        _checkAndClose();
    }

    // ===================== Campaign 结束 =====================

    /// @notice A 主动关闭 campaign，阻止新 claim，不影响已有 pending claims
    function closeCampaign() external onlyA {
        if (campaignStatus != OPEN) revert CampaignNotOpen();
        campaignStatus = CLOSED;
    }

    /// @notice CLOSED 且无 pending 时，A 提取剩余预算
    function withdrawRemaining() external onlyA nonReentrant {
        if (campaignStatus != CLOSED) revert NotClosed();
        if (pendingClaims > 0) revert PendingClaims();
        if (budget == 0) revert NoFunds();

        uint96 amt = budget;
        budget = 0;
        if (!IERC20(feeToken).transfer(partyA, amt)) revert TransferFailed();
    }

    // ===================== 内部辅助函数 =====================

    function _claimCost() internal view returns (uint96) {
        return rewardPerFollow + verifierFee + protocolFee;
    }

    function _checkAndClose() internal {
        if (campaignStatus != OPEN) return;
        if (block.timestamp > deadline) {
            campaignStatus = CLOSED;
        } else if (budget < _claimCost() && pendingClaims == 0) {
            campaignStatus = CLOSED;
        }
    }

    function _hasPendingClaim(address addr) internal view returns (bool) {
        uint256 idx = pendingClaimIndex[addr];
        return claims[idx].claimer == addr && claims[idx].status == VERIFYING;
    }

    function _isVerificationTimedOut(Claim storage c) internal view returns (bool) {
        return block.timestamp > uint256(c.timestamp) + VERIFICATION_TIMEOUT;
    }

    function _verifyVerifierSignature(
        address verifier_,
        uint64 targetUserId,
        uint96 fee,
        uint256 sigDeadline,
        bytes calldata sig
    ) internal view {
        address verifierSpec = IVerifier(verifier_).spec();
        if (verifierSpec != requiredSpec) revert InvalidSpecAddress();
        address recovered = XFollowVerifierSpec(verifierSpec).check(
            verifier_, targetUserId, uint256(fee), sigDeadline, sig
        );
        if (recovered != IVerifier(verifier_).signer()) revert InvalidVerifierSignature();
    }

    // ===================== 查询函数 =====================

    /// @notice 每次 claim 的总成本
    function claimCost() external view returns (uint96) {
        return _claimCost();
    }

    /// @notice 剩余可 claim 次数
    function remainingSlots() external view returns (uint256) {
        uint96 cost = _claimCost();
        if (cost == 0) return 0;
        return uint256(budget) / uint256(cost);
    }

    /// @notice 指定地址 + userId 是否可 claim（含绑定检查）
    function canClaim(address addr, uint64 userId, bytes calldata bindingSig) external view returns (bool) {
        if (campaignStatus != OPEN) return false;
        if (block.timestamp > deadline) return false;
        if (budget < _claimCost()) return false;
        if (claimedAddress[addr]) return false;
        if (claimedUserId[userId]) return false;
        if (failCount[addr] >= MAX_FAILURES) return false;
        if (_hasPendingClaim(addr)) return false;
        if (!bindingAttestation.verify(addr, userId, bindingSig)) return false;
        return true;
    }

    /// @notice 地址的失败次数
    function failures(address addr) external view returns (uint8) {
        return failCount[addr];
    }

    // ===================== IDeal 实现 =====================

    function name() external pure override returns (string memory) {
        return "X Follow Campaign";
    }

    function description() external pure override returns (string memory) {
        return "Campaign: pay fixed USDC reward per X follow. 1-to-many, auto-verified via twitterapi.io + twitter-api45. Binding Attestation required.";
    }

    function tags() external pure override returns (string[] memory) {
        string[] memory t = new string[](2);
        t[0] = "x";
        t[1] = "follow";
        return t;
    }

    function version() external pure override returns (string memory) {
        return "5.0";
    }

    function protocolFeePolicy() external pure override returns (string memory) {
        return
            "Per-claim protocol fee deducted from campaign budget on successful claims only. "
            "claimCost = rewardPerFollow + verifierFee + protocolFee. "
            "Failed claims: only verifierFee deducted. Inconclusive: full refund. "
            "Query exact value via claimCost().";
    }

    function requiredSpecs() external view override returns (address[] memory) {
        address[] memory specs = new address[](1);
        specs[0] = requiredSpec;
        return specs;
    }

    function verificationParams(uint256 dealIndex, uint256 verificationIndex)
        external view override onlySlot0(verificationIndex)
        returns (address, uint256, uint256, bytes memory, bytes memory)
    {
        Claim storage c = claims[dealIndex];
        if (c.claimer == address(0)) revert InvalidParams();

        bytes memory specParams = abi.encode(c.follower_user_id, target_user_id);
        return (verifier, uint256(verifierFee), signatureDeadline, verifierSignature, specParams);
    }

    /// @notice claim() 内部自动触发验证，外部调用始终 revert
    function requestVerification(uint256, uint256) external pure override {
        revert("use claim() instead");
    }

    /// @notice 平台级统一交易阶段（per-claim）
    function phase(uint256 dealIndex) external view override returns (uint8) {
        Claim storage c = claims[dealIndex];
        if (c.claimer == address(0)) return 0; // NotFound
        if (c.status == VERIFYING) return 2;   // Active
        if (c.status == COMPLETED) return 3;   // Success
        return 4;                               // Failed (REJECTED / TIMED_OUT / INCONCLUSIVE)
    }

    /// @notice 业务级状态码（per-claim，含派生状态）
    function dealStatus(uint256 dealIndex) external view override returns (uint8) {
        Claim storage c = claims[dealIndex];
        if (c.claimer == address(0)) return NOT_FOUND;

        if (c.status == VERIFYING) {
            if (_isVerificationTimedOut(c)) {
                return VERIFIER_TIMED_OUT;
            }
            return VERIFYING;
        }
        return c.status;
    }

    function dealExists(uint256 dealIndex) external view override returns (bool) {
        return claims[dealIndex].claimer != address(0);
    }

    /// @notice 合约级营业状态：OPEN → OPENING，CLOSED → CLOSED
    function serviceMode() external view override returns (uint8) {
        return campaignStatus == OPEN ? MODE_OPENING : MODE_CLOSED;
    }

    function instruction() external view override returns (string memory) {
        return
            "# X Follow Campaign\n\n"
            "Pay fixed USDC reward per follow to a target account on X. 1-to-many campaign model.\n\n"
            "## Campaign Lifecycle\n\n"
            "OPEN -> CLOSED\n\n"
            "- **OPEN**: Campaign goes live immediately after initialization. Params are locked, anyone with Binding Attestation can claim().\n"
            "- **CLOSED**: Auto-triggered on deadline or budget exhaustion. A calls withdrawRemaining().\n\n"
            "## For Followers (B)\n\n"
            "1. Complete Twitter verification on Platform to get Binding Attestation\n"
            "2. Follow the target account on X\n"
            "3. Call `claim(userId, bindingSig)` with your attestation\n"
            "4. Wait for verification result\n\n"
            "## Costs\n\n"
            "B pays nothing. All fees (reward + verifierFee + protocolFee) come from A's budget.\n"
            "Query `claimCost()` for per-claim cost, `remainingSlots()` for available claims.\n"
            "Query `canClaim(addr, userId, bindingSig)` for full pre-flight check (address + userId dedup + binding attestation).\n\n"
            "## Fee Policy\n\n"
            "- Successful claim: reward to B, verifierFee to Verifier, protocolFee to Developer.\n"
            "- Failed claim (not following): only verifierFee deducted, reward + protocolFee refunded to budget.\n"
            "- Inconclusive (API error): full refund to budget.\n\n"
            "## Failure Policy\n\n"
            "Failed claims (not following) increment failCount. After 3 failures, banned from this campaign.\n"
            "Inconclusive results (API errors) do not count as failures.\n\n"
            "## Withdrawing Remaining Budget (A)\n\n"
            "1. Campaign must be CLOSED (auto on deadline/budget, or call `closeCampaign()`)\n"
            "2. If pending claims exist, wait for verification timeout (30 min), then call `resetVerification(dealIndex, 0)` for each\n"
            "3. Once `pendingClaims == 0`, call `withdrawRemaining()` to reclaim budget\n";
    }
}
