// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealBase.sol";
import "./IVerifier.sol";
import "./XFollowVerifierSpec.sol";
import "./IERC20.sol";
import "./Initializable.sol";
import "./ERC2771Mixin.sol";


/// @title XFollowDealContract - X 付费关注 Campaign 合约
/// @notice 合约即 campaign。A 存入预算，任何 TwitterRegistry 认证用户可关注后领取固定奖励。
///         每个 B 的 claim() 创建一个新的 dealIndex。全自动，无需协商。
/// @dev 生命周期：OPEN → CLOSED
///      OPEN：createDeal() 成功后立即生效，接受 claim
///      CLOSED：不接受新 claim（deadline 到期或预算耗尽自动触发）
contract XFollowDealContract is DealBase, Initializable, ERC2771Mixin {

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
    error NotVerified();
    error PendingClaim();
    error NotClosed();
    error PendingClaims();
    error NoFunds();
    error VerificationNotTimedOut();
    error VerificationTimedOut();
    error InvalidVerificationIndex();
    error InsufficientBudget();

    // ===================== dealStatus 常量（per-claim） =====================
    //
    //   存储基础值          dealStatus 派生值
    //   ─────────────       ──────────────────
    //   VERIFYING      (0)  → VERIFIER_TIMED_OUT (1)
    //   COMPLETED      (2)
    //   REJECTED       (3)
    //   TIMED_OUT      (4)
    //   NOT_FOUND     (255)

    uint8 constant VERIFYING            = 0;
    uint8 constant VERIFIER_TIMED_OUT   = 1;
    uint8 constant COMPLETED            = 2;
    uint8 constant REJECTED             = 3;
    uint8 constant TIMED_OUT            = 4;
    uint8 constant NOT_FOUND            = 255;

    // ===================== campaignStatus 常量 =====================

    uint8 constant OPEN                 = 1;
    uint8 constant CLOSED               = 2;

    // ===================== 类型 =====================

    struct Claim {
        address claimer;             // B 的地址
        uint48  timestamp;           // claim 创建时间
        uint8   status;              // VERIFYING / COMPLETED / REJECTED / TIMED_OUT
        uint64  follower_user_id;    // claim 时从 TwitterRegistry 读取
    }

    // ===================== 常量 =====================

    uint96 public constant MIN_PROTOCOL_FEE = 10_000;
    uint256 public constant VERIFICATION_TIMEOUT = 30 minutes;
    uint8 public constant MAX_FAILURES = 3;

    address public immutable FEE_COLLECTOR;
    uint96 public immutable PROTOCOL_FEE;
    address public immutable REQUIRED_SPEC;
    address public immutable TWITTER_REGISTRY;

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

    // ===================== Per-Claim 存储 =====================

    mapping(uint256 => Claim) internal claims;
    mapping(address => bool)  public claimed;
    mapping(address => uint8) public failCount;
    mapping(address => uint256) internal pendingClaimIndex;  // B → 当前 pending 的 dealIndex

    // ===================== 修饰器 =====================

    modifier onlyA() {
        if (_msgSender() != partyA) revert NotPartyA();
        _;
    }

    modifier onlySlot0(uint256 verificationIndex) {
        if (verificationIndex != 0) revert InvalidVerificationIndex();
        _;
    }

    // ===================== 构造函数 =====================

    constructor(address feeCollector, uint96 protocolFee_, address requiredSpec, address twitterRegistry) {
        _setInitializer();
        if (feeCollector == address(0) || feeCollector == address(this) || feeCollector.code.length == 0) {
            revert InvalidParams();
        }
        if (protocolFee_ < MIN_PROTOCOL_FEE) revert InvalidParams();
        if (requiredSpec == address(0)) revert InvalidSpecAddress();
        if (twitterRegistry == address(0)) revert InvalidParams();
        FEE_COLLECTOR = feeCollector;
        PROTOCOL_FEE = protocolFee_;
        REQUIRED_SPEC = requiredSpec;
        TWITTER_REGISTRY = twitterRegistry;
    }

    // ===================== Campaign 设置 =====================

    /// @notice 创建 campaign（仅一次），成功后立即进入 OPEN
    function createDeal(
        uint96  grossAmount,
        address verifier_,
        uint96  verifierFee_,
        uint96  rewardPerFollow_,
        uint256 sigDeadline,
        bytes calldata sig,
        uint64  target_user_id_,
        uint48  deadline_
    ) external returns (uint256) {
        if (partyA != address(0)) revert AlreadyInitialized();
        address sender = _msgSender();

        if (rewardPerFollow_ == 0) revert InvalidParams();
        if (deadline_ <= block.timestamp) revert InvalidParams();
        if (verifier_ == address(0)) revert InvalidParams();
        if (sender == verifier_) revert InvalidParams();
        if (verifier_.code.length == 0) revert VerifierNotContract();
        if (sig.length == 0) revert InvalidVerifierSignature();
        if (sigDeadline < deadline_) revert SignatureExpired();
        if (grossAmount < rewardPerFollow_ + verifierFee_ + PROTOCOL_FEE) revert InsufficientBudget();

        if (target_user_id_ == 0) revert InvalidParams();

        _verifyVerifierSignature(verifier_, target_user_id_, verifierFee_, sigDeadline, sig);

        // USDC 转入
        if (!IERC20(feeToken).transferFrom(sender, address(this), grossAmount)) revert TransferFailed();

        // 设置 campaign
        partyA = sender;
        campaignStatus = OPEN;
        verifier = verifier_;
        rewardPerFollow = rewardPerFollow_;
        verifierFee = verifierFee_;
        deadline = deadline_;
        budget = grossAmount;
        signatureDeadline = sigDeadline;
        target_user_id = target_user_id_;
        verifierSignature = sig;

        return 0; // campaign 本身不需要 dealIndex
    }

    // ===================== Claim（每个 claim = 一个 dealIndex） =====================

    /// @notice B 领取关注奖励。无参数，合约从 TwitterRegistry 读取 B 的 user_id。
    function claim() external returns (uint256 dealIndex) {
        // 检查并可能触发 auto-close
        _checkAndClose();
        if (campaignStatus != OPEN) revert CampaignNotOpen();

        address sender = _msgSender();
        if (claimed[sender]) revert AlreadyClaimed();
        if (failCount[sender] >= MAX_FAILURES) revert MaxFailures();

        // 检查是否有 pending claim
        if (_hasPendingClaim(sender)) revert PendingClaim();

        // 从 TwitterRegistry 读取 user_id
        (bool success, bytes memory data) = TWITTER_REGISTRY.staticcall(
            abi.encodeWithSignature("userIdOf(address)", sender)
        );
        if (!success) revert NotVerified();
        uint64 followerUserId = abi.decode(data, (uint64));
        if (followerUserId == 0) revert NotVerified();

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
        pendingClaims++;

        _emitStateChanged(dealIndex, VERIFYING);
        _emitPhaseChanged(dealIndex, 2); // → Active

        emit VerificationRequested(dealIndex, 0, verifier);
    }

    // ===================== 验证结果回调 =====================

    /// @notice Verifier 提交验证结果
    function onVerificationResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata /* reason */)
        external override onlySlot0(verificationIndex)
    {
        if (msg.sender != verifier) revert NotVerifier();
        Claim storage c = claims[dealIndex];
        if (c.status != VERIFYING) revert InvalidStatus();
        if (_isVerificationTimedOut(c)) revert VerificationTimedOut();

        uint96 reward = rewardPerFollow;
        uint96 vFee = verifierFee;
        uint96 pFee = PROTOCOL_FEE;
        address claimer = c.claimer;

        pendingClaims--;
        delete pendingClaimIndex[claimer];

        emit VerificationReceived(dealIndex, verificationIndex, msg.sender, result);

        if (result > 0) {
            // 通过：付款给 B
            c.status = COMPLETED;
            claimed[claimer] = true;
            completedClaims++;

            _emitStateChanged(dealIndex, COMPLETED);
            _emitPhaseChanged(dealIndex, 3); // → Success

            if (!IERC20(feeToken).transfer(claimer, reward)) revert TransferFailed();
            if (vFee > 0) {
                if (!IERC20(feeToken).transfer(msg.sender, vFee)) revert TransferFailed();
            }
            if (!IERC20(feeToken).transfer(FEE_COLLECTOR, pFee)) revert TransferFailed();

        } else if (result < 0) {
            // 失败：奖励退回预算，verifier + protocol 照付
            c.status = REJECTED;
            failCount[claimer]++;
            budget += reward;

            _emitStateChanged(dealIndex, REJECTED);
            _emitPhaseChanged(dealIndex, 4); // → Failed

            if (vFee > 0) {
                if (!IERC20(feeToken).transfer(msg.sender, vFee)) revert TransferFailed();
            }
            if (!IERC20(feeToken).transfer(FEE_COLLECTOR, pFee)) revert TransferFailed();

        } else {
            // 不确定：全额退回预算
            c.status = REJECTED;
            budget += reward + vFee + pFee;

            _emitStateChanged(dealIndex, REJECTED);
            _emitPhaseChanged(dealIndex, 4); // → Failed
        }

        // 检查是否应 auto-close
        _checkAndClose();
    }

    // ===================== 验证超时重置 =====================

    /// @notice Verifier 超时后重置 claim，全额退回预算
    function resetVerification(uint256 dealIndex, uint256 verificationIndex)
        external onlySlot0(verificationIndex)
    {
        Claim storage c = claims[dealIndex];
        if (c.status != VERIFYING) revert InvalidStatus();
        if (!_isVerificationTimedOut(c)) revert VerificationNotTimedOut();

        c.status = TIMED_OUT;
        pendingClaims--;
        delete pendingClaimIndex[c.claimer];
        budget += _claimCost();

        _emitStateChanged(dealIndex, TIMED_OUT);
        _emitPhaseChanged(dealIndex, 4); // → Failed

        _checkAndClose();
    }

    // ===================== Campaign 结束 =====================

    /// @notice CLOSED 且无 pending 时，A 提取剩余预算
    function withdrawRemaining() external onlyA {
        if (campaignStatus != CLOSED) revert NotClosed();
        if (pendingClaims > 0) revert PendingClaims();
        if (budget == 0) revert NoFunds();

        uint96 amt = budget;
        budget = 0;
        if (!IERC20(feeToken).transfer(partyA, amt)) revert TransferFailed();
    }

    // ===================== 内部辅助函数 =====================

    function _claimCost() internal view returns (uint96) {
        return rewardPerFollow + verifierFee + PROTOCOL_FEE;
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
        if (verifierSpec != REQUIRED_SPEC) revert InvalidSpecAddress();
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

    /// @notice 指定地址是否可 claim
    function canClaim(address addr) external view returns (bool) {
        if (campaignStatus != OPEN) return false;
        if (block.timestamp > deadline) return false;
        if (budget < _claimCost()) return false;
        if (claimed[addr]) return false;
        if (failCount[addr] >= MAX_FAILURES) return false;
        if (_hasPendingClaim(addr)) return false;
        // 检查 TwitterRegistry（staticcall 不 revert）
        (bool success, bytes memory data) = TWITTER_REGISTRY.staticcall(
            abi.encodeWithSignature("userIdOf(address)", addr)
        );
        if (!success) return false;
        uint64 userId = abi.decode(data, (uint64));
        return userId != 0;
    }

    /// @notice 地址的失败次数
    function failures(address addr) external view returns (uint8) {
        return failCount[addr];
    }

    // ===================== IDeal 实现 =====================

    function name() external pure override returns (string memory) {
        return "X Follow Deal";
    }

    function description() external pure override returns (string memory) {
        return "Campaign: pay fixed USDC reward per X follow. 1-to-many, auto-verified via twitterapi.io + twitter-api45. TwitterRegistry identity required.";
    }

    function tags() external pure override returns (string[] memory) {
        string[] memory t = new string[](2);
        t[0] = "x";
        t[1] = "follow";
        return t;
    }

    function version() external pure override returns (string memory) {
        return "3.0";
    }

    function protocolFeePolicy() external pure override returns (string memory) {
        return
            "Per-claim protocol fee deducted from campaign budget. "
            "claimCost = rewardPerFollow + verifierFee + protocolFee. "
            "No upfront fee at campaign creation. "
            "Query exact value via claimCost().";
    }

    function requiredSpecs() external view override returns (address[] memory) {
        address[] memory specs = new address[](1);
        specs[0] = REQUIRED_SPEC;
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
        return 4;                               // Failed
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

    function instruction() external view override returns (string memory) {
        return
            "# X Follow Deal (Campaign)\n\n"
            "Pay fixed USDC reward per follow to a target account on X. 1-to-many campaign model.\n\n"
            "## Campaign Lifecycle\n\n"
            "OPEN -> CLOSED\n\n"
            "- **OPEN**: Campaign goes live immediately after createDeal(). Params are locked, anyone with TwitterRegistry binding can claim().\n"
            "- **CLOSED**: Auto-triggered on deadline or budget exhaustion. A calls withdrawRemaining().\n\n"
            "## For Followers (B)\n\n"
            "1. Bind your Twitter via TwitterRegistry (if not already)\n"
            "2. Follow the target account on X\n"
            "3. Call `claim()` (no parameters needed)\n"
            "4. Wait for verification result\n\n"
            "## Costs\n\n"
            "B pays nothing. All fees (reward + verifierFee + protocolFee) come from A's budget.\n"
            "Query `claimCost()` for per-claim cost, `remainingSlots()` for available claims.\n\n"
            "## Failure Policy\n\n"
            "Failed claims (not following) increment failCount. After 3 failures, banned from this campaign.\n"
            "Inconclusive results (API errors) do not count as failures.\n";
    }
}
