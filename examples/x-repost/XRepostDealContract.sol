// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealBase.sol";
import "./IVerifier.sol";
import "./XRepostVerifierSpec.sol";
import "./IERC20.sol";
import "./Initializable.sol";
import "./FeeFormat.sol";


/// @title XRepostDealContract - X Repost (retweet OR quote) Deal Contract
/// @notice Single contract managing all repost deals. Verifier accepts EITHER a native retweet
///         OR a quote tweet. No time window — old posts count. feeToken set via setFeeToken() once.
/// @dev USDC approve · Packed storage · Custom errors · Direct payout
///      Unified dealStatus — status field stores dealStatus base value directly, no internal State enum
///
///      Differences vs XQuoteDealContract:
///      - No quote_tweet_id field (Poster does not submit a repost id; verifier searches)
///      - claimDone takes no extra argument
///      - EIP-712 signature path binds reposter address (poster) cryptographically via XRepostVerifierSpec
///      - specParams = abi.encode(tweet_id, poster) — no repost id
///      - System does NOT deduplicate reposts across deals (Sponsor's judgment)
///
///      Deal flow overview:
///      1. Sponsor creates deal, deposits USDC (reward + protocolFee), specifying Poster and Verifier
///      2. Poster accepts deal (protocolFee sent to FeeCollector at this point)
///      3. Poster reposts (retweet or quote) the tweet on X, then calls claimDone
///      4. Sponsor manually confirms payment, or requests Verifier auto-verification
///      5. If verification is inconclusive or Verifier times out, enters settlement phase
contract XRepostDealContract is DealBase, Initializable {

    // ===================== Errors =====================

    error NotSponsor();
    error NotPoster();
    error NotVerifier();
    error NotSponsorOrPoster();
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
    error Reentrancy();
    error FeeTokenNotSet();
    error VersionMismatch();

    // ===================== dealStatus Constants =====================
    // Base values (written to storage) and derived values (computed at runtime by dealStatus() only).
    //
    //   Storage base value      dealStatus derived value
    //   ─────────────           ──────────────────
    //   WAITING_ACCEPT (0)      → ACCEPT_TIMED_OUT (1)
    //   WAITING_CLAIM  (2)      → CLAIM_TIMED_OUT (3)
    //   WAITING_CONFIRM(4)      → CONFIRM_TIMED_OUT (5)
    //   VERIFYING      (6)      → VERIFIER_TIMED_OUT (7)
    //   SETTLING       (8)      → SETTLEMENT_PROPOSED (9), SETTLEMENT_TIMED_OUT (10)
    //   COMPLETED     (11)
    //   VIOLATED      (12)
    //   CANCELLED     (13)
    //   FORFEITED     (14)
    //   NOT_FOUND    (255)      — deal does not exist

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

    // ===================== Types =====================

    /// @dev Packed into minimal storage slots.
    ///      Single-verification specialization (requiredSpecs().length == 1).
    struct Deal {
        // Slot 1 (28/32 bytes)
        address sponsor;                   // 20 bytes — Sponsor address (initiator/payer)
        uint48  stageTimestamp;           // 6 bytes  — Current stage start time
        uint8   status;                   // 1 byte   — dealStatus base value
        bool    isRequesterSponsor;             // 1 byte   — Whether verification requester is Sponsor (for timeout refund)
        // Slot 2
        address poster;                   // 20 bytes — Poster address (executor/reposter)
        uint96  amount;                   // 12 bytes — Escrowed amount (grossAmount - protocolFee)
        // Slot 3 — Verifier info (slot 0)
        address verifier;                 // 20 bytes — Verifier contract address
        uint96  verifierFee;              // 12 bytes — Verification fee
        // Slot 4 (26/32 bytes — violator and verificationTimestamp are mutually exclusive)
        address violator;                 // 20 bytes — Violator address
        uint48  verificationTimestamp;    // 6 bytes  — Verification request timestamp
        // Slot 5 — Signature deadline (slot 0)
        uint256 signatureDeadline;
        // Dynamic types (each occupies independent storage slots)
        string  tweet_id;                 // Tweet ID to be reposted
        bytes   verifierSignature;        // EIP-712 signature (slot 0, 65 bytes)
    }

    /// @dev Settlement proposal, only used in Settling state
    struct Settlement {
        address proposer;     // 20 bytes — Proposer
        uint96  amountToSponsor;    // 12 bytes — Proposed amount for Sponsor (remainder goes to Poster)
        uint256 version;      // Proposal version, incremented on each proposal
    }

    // ===================== Constants =====================

    uint96 public constant MIN_PROTOCOL_FEE = 10_000;
    uint256 public constant STAGE_TIMEOUT = 30 minutes;
    uint256 public constant VERIFICATION_TIMEOUT = 30 minutes;
    uint256 public constant SETTLING_TIMEOUT = 12 hours;
    uint256 public constant CONFIRM_GRACE_PERIOD = 1 hours;

    address public immutable FEE_COLLECTOR;
    uint96 public immutable PROTOCOL_FEE;
    address public immutable REQUIRED_SPEC;

    // ===================== Storage =====================

    uint256 private _lock = 1;

    mapping(uint256 => Deal) internal deals;
    mapping(uint256 => Settlement) internal settlementBySponsor;
    mapping(uint256 => Settlement) internal settlementByPoster;

    // ===================== Modifiers =====================

    modifier onlySponsor(uint256 dealIndex) {
        if (msg.sender != deals[dealIndex].sponsor) revert NotSponsor();
        _;
    }

    modifier onlyPoster(uint256 dealIndex) {
        if (msg.sender != deals[dealIndex].poster) revert NotPoster();
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

    // ===================== Constructor =====================

    constructor(address feeCollector, uint96 protocolFee_, address requiredSpec) {
        _setInitializer();
        if (feeCollector == address(0) || feeCollector == address(this) || feeCollector.code.length == 0) {
            revert InvalidFeeCollector();
        }
        if (protocolFee_ < MIN_PROTOCOL_FEE) revert FeeTooLow();
        if (requiredSpec == address(0) || requiredSpec.code.length == 0) revert InvalidSpecAddress();
        FEE_COLLECTOR = feeCollector;
        PROTOCOL_FEE = protocolFee_;
        REQUIRED_SPEC = requiredSpec;
    }

    // ===================== Create Deal =====================

    /// @notice Create a deal (requires pre-approved USDC)
    /// @dev The verifier signature is bound to `poster` (reposter) via XRepostVerifierSpec.check().
    function createDeal(
        address poster,
        uint96  grossAmount,
        address verifier,
        uint96  verifierFee,
        uint256 deadline,
        bytes calldata sig,
        string calldata tweet_id
    ) external nonReentrant returns (uint256 dealIndex) {
        // --- Validation ---
        if (feeToken == address(0)) revert FeeTokenNotSet();
        if (grossAmount <= PROTOCOL_FEE) revert InvalidParams();
        if (verifierFee > grossAmount - PROTOCOL_FEE) revert InvalidParams();
        if (poster == address(0)) revert InvalidParams();
        if (msg.sender == poster) revert InvalidParams();

        if (verifier == address(0)) revert InvalidParams();
        if (msg.sender == verifier || poster == verifier) revert InvalidParams();
        if (verifier.code.length == 0) revert VerifierNotContract();
        if (sig.length == 0) revert InvalidVerifierSignature();
        if (deadline < block.timestamp) revert SignatureExpired();

        if (bytes(tweet_id).length == 0) revert InvalidParams();

        _verifyVerifierSignature(verifier, tweet_id, poster, verifierFee, deadline, sig);

        // --- Transfer USDC to escrow ---
        if (!IERC20(feeToken).transferFrom(msg.sender, address(this), grossAmount)) revert TransferFailed();

        // --- Create deal record ---
        {
            address[] memory traders = new address[](2);
            traders[0] = msg.sender;
            traders[1] = poster;
            address[] memory verifiers = new address[](1);
            verifiers[0] = verifier;
            dealIndex = _recordStart(traders, verifiers);
        }

        {
            Deal storage d = deals[dealIndex];
            d.sponsor = msg.sender;
            d.poster = poster;
            d.verifier = verifier;
            d.amount = grossAmount - PROTOCOL_FEE;
            d.verifierFee = verifierFee;
            d.tweet_id = tweet_id;
            d.signatureDeadline = deadline;
            d.verifierSignature = sig;
            d.status = WAITING_ACCEPT;
            d.stageTimestamp = uint48(block.timestamp);
        }

        _emitStatusChanged(dealIndex, WAITING_ACCEPT);
    }

    // ===================== Core Flow =====================

    /// @notice Poster accepts the deal
    function accept(uint256 dealIndex)
        external
        nonReentrant
    {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.poster) revert NotPoster();
        if (d.status != WAITING_ACCEPT) revert InvalidStatus();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();

        uint96 fee = PROTOCOL_FEE;
        d.status = WAITING_CLAIM;
        d.stageTimestamp = uint48(block.timestamp);

        _emitPhaseChanged(dealIndex, 2); // → Active
        _emitStatusChanged(dealIndex, WAITING_CLAIM);

        if (!IERC20(feeToken).transfer(FEE_COLLECTOR, fee)) revert TransferFailed();
    }

    /// @notice Poster declares the repost is done (no tweet id required — verifier searches)
    function claimDone(uint256 dealIndex)
        external
        nonReentrant
    {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.poster) revert NotPoster();
        if (d.status != WAITING_CLAIM) revert InvalidStatus();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();

        d.status = WAITING_CONFIRM;
        d.stageTimestamp = uint48(block.timestamp);

        _emitStatusChanged(dealIndex, WAITING_CONFIRM);
    }

    /// @notice Sponsor manually confirms and pays Poster directly (skipping verification)
    function confirmAndPay(uint256 dealIndex)
        external
        nonReentrant
    {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.sponsor) revert NotSponsor();
        if (d.status != WAITING_CONFIRM) revert InvalidStatus();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();

        uint96 amt = d.amount;
        d.amount = 0;
        d.status = COMPLETED;

        _emitStatusChanged(dealIndex, COMPLETED);
        _emitPhaseChanged(dealIndex, 3); // → Success

        if (!IERC20(feeToken).transfer(d.poster, amt)) revert TransferFailed();
    }

    // ===================== Cancel (WAITING_ACCEPT → CANCELLED) =====================

    /// @notice Sponsor cancels a deal that Poster has not yet accepted (WAITING_ACCEPT + timed out)
    function cancelDeal(uint256 dealIndex)
        external
        nonReentrant
        onlySponsor(dealIndex)
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
            if (!IERC20(feeToken).transfer(d.sponsor, amt)) revert TransferFailed();
        }
    }

    // ===================== Verification =====================

    /// @notice Trader triggers verification (caller pays fee via approve)
    function requestVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        nonReentrant
        override
    {
        if (verificationIndex != 0) revert InvalidVerificationIndex();

        Deal storage d = deals[dealIndex];
        if (d.status != WAITING_CONFIRM) revert InvalidStatus();
        if (msg.sender != d.sponsor && msg.sender != d.poster) revert NotSponsorOrPoster();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();

        uint96 fee = d.verifierFee;
        address verifier = d.verifier;

        // CEI: state changes first
        d.status = VERIFYING;
        d.isRequesterSponsor = (msg.sender == d.sponsor);
        d.verificationTimestamp = uint48(block.timestamp);

        emit VerificationRequested(dealIndex, verificationIndex, verifier);

        if (!IERC20(feeToken).transferFrom(msg.sender, address(this), fee)) revert TransferFailed();
    }

    /// @notice Verifier submits verification result
    /// @dev result > 0 → passed, pay Poster
    ///      result < 0 → failed, Poster violated
    ///      result == 0 → inconclusive, enter settlement
    function onVerificationResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason) external nonReentrant override onlySlot0(verificationIndex) {
        Deal storage d = deals[dealIndex];

        if (msg.sender != d.verifier) revert NotVerifier();
        if (d.status != VERIFYING) revert InvalidStatus();
        if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) revert AlreadyTimedOut();

        // Clear verification timestamp
        d.verificationTimestamp = 0;

        uint96 vFee = d.verifierFee;
        uint96 transferToPoster = 0;

        if (result > 0) {
            transferToPoster = d.amount;
            d.amount = 0;
            d.status = COMPLETED;
        } else if (result < 0) {
            d.status = VIOLATED;
            d.violator = d.poster;
        } else {
            d.status = SETTLING;
            d.stageTimestamp = uint48(block.timestamp);
        }

        // --- Events ---
        emit VerificationReceived(dealIndex, verificationIndex, msg.sender, result);

        if (result > 0) {
            _emitStatusChanged(dealIndex, COMPLETED);
            _emitPhaseChanged(dealIndex, 3); // → Success
        } else if (result < 0) {
            _emitViolated(dealIndex, d.poster, reason);
            _emitStatusChanged(dealIndex, VIOLATED);
            _emitPhaseChanged(dealIndex, 4); // → Failed
        } else {
            _emitStatusChanged(dealIndex, SETTLING);
        }

        // --- Interactions: all transfers last ---
        if (vFee > 0) {
            if (result == 0) {
                // inconclusive — verifier did not complete work, refund verifierFee to requester
                address requester = d.isRequesterSponsor ? d.sponsor : d.poster;
                if (!IERC20(feeToken).transfer(requester, vFee)) revert TransferFailed();
            } else {
                if (!IERC20(feeToken).transfer(msg.sender, vFee)) revert TransferFailed();
            }
        }
        if (transferToPoster > 0) {
            if (!IERC20(feeToken).transfer(d.poster, transferToPoster)) revert TransferFailed();
        }
    }

    // ===================== Verification Reset =====================

    /// @notice Reset verification after verifier timeout, refund verification fee, enter settlement
    function resetVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        nonReentrant
        atStatus(dealIndex, VERIFYING)
        onlySlot0(verificationIndex)
    {
        Deal storage d = deals[dealIndex];
        address sender = msg.sender;
        if (sender != d.sponsor && sender != d.poster) revert NotSponsorOrPoster();
        if (block.timestamp <= uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT)
            revert VerificationNotTimedOut();

        address requester = d.isRequesterSponsor ? d.sponsor : d.poster;
        uint96 vFee = d.verifierFee;

        // CEI: state changes first
        d.verificationTimestamp = 0;
        d.status = SETTLING;
        d.stageTimestamp = uint48(block.timestamp);

        _emitViolated(dealIndex, d.verifier, "verifier timeout");
        _emitStatusChanged(dealIndex, SETTLING);

        if (vFee > 0) {
            if (!IERC20(feeToken).transfer(requester, vFee)) revert TransferFailed();
        }
    }

    // ===================== Settlement =====================

    /// @notice Propose a settlement: amountToSponsor is the amount for Sponsor (remainder goes to Poster)
    /// @dev Dual-proposal mode: Sponsor/Poster each maintain independent proposals, no overwriting. New proposals blocked after 12h.
    ///      Version incremented on each proposal; expectedVersion required on confirm to prevent front-running.
    function proposeSettlement(uint256 dealIndex, uint96 amountToSponsor)
        external
        nonReentrant
    {
        Deal storage d = deals[dealIndex];
        if (d.status != SETTLING) revert InvalidStatus();
        if (msg.sender != d.sponsor && msg.sender != d.poster) revert NotSponsorOrPoster();
        if (_isStageTimedOut(dealIndex)) revert AlreadyTimedOut();
        if (amountToSponsor > d.amount) revert InvalidSettlement();

        uint256 newVersion;
        if (msg.sender == d.sponsor) {
            Settlement storage s = settlementBySponsor[dealIndex];
            s.proposer = msg.sender;
            s.amountToSponsor = amountToSponsor;
            s.version += 1;
            newVersion = s.version;
        } else {
            Settlement storage s = settlementByPoster[dealIndex];
            s.proposer = msg.sender;
            s.amountToSponsor = amountToSponsor;
            s.version += 1;
            newVersion = s.version;
        }

        emit SettlementProposed(dealIndex, msg.sender, amountToSponsor, newVersion);
    }

    /// @notice Confirm counterparty's settlement proposal
    /// @dev Within 12h: normal confirm; 12h~13h grace period: can still confirm existing proposals (but not create new ones); after 13h: locked.
    /// @param expectedVersion Expected proposal version, prevents front-running
    function confirmSettlement(uint256 dealIndex, uint256 expectedVersion)
        external
        nonReentrant
    {
        Deal storage d = deals[dealIndex];
        if (d.status != SETTLING) revert InvalidStatus();
        if (msg.sender != d.sponsor && msg.sender != d.poster) revert NotSponsorOrPoster();

        // Get counterparty's proposal
        Settlement storage stl = (msg.sender == d.sponsor) ? settlementByPoster[dealIndex] : settlementBySponsor[dealIndex];
        if (stl.proposer == address(0)) revert InvalidSettlement();
        if (stl.version != expectedVersion) revert VersionMismatch();

        // Timeout check: within 12h OK; 12h~13h grace OK; after 13h locked
        uint256 graceDeadline = uint256(d.stageTimestamp) + SETTLING_TIMEOUT + CONFIRM_GRACE_PERIOD;
        if (block.timestamp > graceDeadline) revert AlreadyTimedOut();

        uint96 toSponsor = stl.amountToSponsor;
        uint96 toPoster = d.amount - toSponsor;
        d.amount = 0;
        d.status = COMPLETED;

        delete settlementBySponsor[dealIndex];
        delete settlementByPoster[dealIndex];

        _emitStatusChanged(dealIndex, COMPLETED);
        _emitPhaseChanged(dealIndex, 3); // → Success

        if (toSponsor > 0) {
            if (!IERC20(feeToken).transfer(d.sponsor, toSponsor)) revert TransferFailed();
        }
        if (toPoster > 0) {
            if (!IERC20(feeToken).transfer(d.poster, toPoster)) revert TransferFailed();
        }
    }

    /// @notice Settlement timeout, funds seized to FeeCollector
    /// @dev When proposals exist, must wait until grace period (13h) expires; when no proposals, triggers after 12h.
    function triggerSettlementTimeout(uint256 dealIndex)
        external
        nonReentrant
        atStatus(dealIndex, SETTLING)
    {
        Deal storage d = deals[dealIndex];
        address sender = msg.sender;
        if (sender != d.sponsor && sender != d.poster) revert NotSponsorOrPoster();

        uint256 settlingDeadline = uint256(d.stageTimestamp) + SETTLING_TIMEOUT;
        bool hasProposal = settlementBySponsor[dealIndex].proposer != address(0)
                        || settlementByPoster[dealIndex].proposer != address(0);

        if (hasProposal) {
            if (block.timestamp <= settlingDeadline + CONFIRM_GRACE_PERIOD) revert SettlementNotTimedOut();
        } else {
            if (block.timestamp <= settlingDeadline) revert SettlementNotTimedOut();
        }

        uint96 seized = d.amount;
        d.amount = 0;
        d.status = FORFEITED;
        delete settlementBySponsor[dealIndex];
        delete settlementByPoster[dealIndex];

        _emitStatusChanged(dealIndex, FORFEITED);
        _emitPhaseChanged(dealIndex, 4); // → Failed

        if (seized > 0) {
            if (!IERC20(feeToken).transfer(FEE_COLLECTOR, seized)) revert TransferFailed();
        }
    }

    // ===================== Timeout =====================

    /// @notice Trigger timeout for current stage
    /// @dev WAITING_CLAIM timeout: Poster didn't claimDone → Poster violated
    ///      WAITING_CONFIRM timeout: Sponsor didn't confirm → auto-pay Poster
    function triggerTimeout(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        if (!_isStageTimedOut(dealIndex)) revert NotTimedOut();

        uint8 s = d.status;

        if (s == WAITING_CLAIM) {
            // Poster didn't claimDone → Poster violated
            if (msg.sender != d.sponsor) revert NotSponsor();
            d.status = VIOLATED;
            d.violator = d.poster;
            _emitViolated(dealIndex, d.poster, "claim timeout");
            _emitStatusChanged(dealIndex, VIOLATED);
            _emitPhaseChanged(dealIndex, 4); // → Failed

        } else if (s == WAITING_CONFIRM) {
            // Sponsor didn't confirm → auto-pay Poster
            if (msg.sender != d.poster) revert NotPoster();
            uint96 amt = d.amount;
            d.amount = 0;
            d.status = COMPLETED;
            _emitStatusChanged(dealIndex, COMPLETED);
            _emitPhaseChanged(dealIndex, 3); // → Success
            if (!IERC20(feeToken).transfer(d.poster, amt)) revert TransferFailed();

        } else {
            revert InvalidStatus();
        }
    }

    /// @notice Withdraw funds after violation
    function withdraw(uint256 dealIndex) external nonReentrant atStatus(dealIndex, VIOLATED) {
        Deal storage d = deals[dealIndex];
        address sender = msg.sender;
        if (sender != d.sponsor && sender != d.poster) revert NotSponsorOrPoster();
        if (sender == d.violator) revert ViolatorCannot();
        if (d.amount == 0) revert NoFunds();

        uint96 amt = d.amount;
        d.amount = 0;

        if (!IERC20(feeToken).transfer(sender, amt)) revert TransferFailed();
    }

    // ===================== Internal Helpers =====================

    function _verifyVerifierSignature(
        address verifier,
        string calldata tweet_id,
        address reposterAddress,
        uint96 fee,
        uint256 deadline,
        bytes calldata sig
    ) internal view {
        address verifierSpec = IVerifier(verifier).spec();
        if (verifierSpec != REQUIRED_SPEC) revert InvalidSpecAddress();
        address recovered = XRepostVerifierSpec(verifierSpec).check(
            verifier, tweet_id, reposterAddress, uint256(fee), deadline, sig
        );
        if (recovered != IVerifier(verifier).signer()) revert InvalidVerifierSignature();
    }

    /// @dev Check if current stage has timed out (based on stageTimestamp)
    function _isStageTimedOut(uint256 dealIndex) internal view returns (bool) {
        Deal storage d = deals[dealIndex];
        uint256 timeout = d.status == SETTLING ? SETTLING_TIMEOUT : STAGE_TIMEOUT;
        return block.timestamp > uint256(d.stageTimestamp) + timeout;
    }

    // ===================== Query Functions =====================

    /// @notice Get remaining time in current stage (seconds)
    function timeRemaining(uint256 dealIndex) external view returns (uint256) {
        Deal storage d = deals[dealIndex];
        uint256 deadline_;
        if (d.status == VERIFYING && d.verificationTimestamp > 0) {
            deadline_ = uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT;
        } else if (d.status == SETTLING) {
            bool hasProposal = settlementBySponsor[dealIndex].proposer != address(0)
                            || settlementByPoster[dealIndex].proposer != address(0);
            deadline_ = uint256(d.stageTimestamp) + SETTLING_TIMEOUT + (hasProposal ? CONFIRM_GRACE_PERIOD : 0);
        } else {
            deadline_ = uint256(d.stageTimestamp) + STAGE_TIMEOUT;
        }
        if (block.timestamp >= deadline_) return 0;
        return deadline_ - block.timestamp;
    }

    /// @notice Check if verification has timed out
    function isVerificationTimedOut(uint256 dealIndex) external view returns (bool) {
        Deal storage d = deals[dealIndex];
        if (d.status != VERIFYING) return false;
        return block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT;
    }

    /// @notice Get both parties' settlement proposal info
    function settlement(uint256 dealIndex) external view returns (
        uint96  proposalBySponsor_amountToSponsor,
        uint96  proposalByPoster_amountToSponsor,
        bool    hasProposalSponsor,
        bool    hasProposalPoster,
        uint256 settlementVersionSponsor,
        uint256 settlementVersionPoster
    ) {
        Settlement storage stlSponsor = settlementBySponsor[dealIndex];
        Settlement storage stlPoster = settlementByPoster[dealIndex];
        return (
            stlSponsor.amountToSponsor,
            stlPoster.amountToSponsor,
            stlSponsor.proposer != address(0),
            stlPoster.proposer != address(0),
            stlSponsor.version,
            stlPoster.version
        );
    }

    /// @notice Check if deal stage has timed out
    function isTimedOut(uint256 dealIndex) external view returns (bool) {
        return _isStageTimedOut(dealIndex);
    }

    // ===================== Standard Identity =====================

    function name() external pure override returns (string memory) {
        return "Sponsored Repost on X (Twitter)";
    }

    function description() external pure override returns (string memory) {
        return
            "Sponsored Repost Contract\n"
            "- Sponsor: Commission a poster to promote a tweet.\n"
            "- Poster: Repost or quote the tweet to claim the reward.\n"
            "- Settlement & Security: USDC-settled; Twitter-binding ensures exclusive delivery.";
    }

    function tags() external pure override returns (string[] memory) {
        string[] memory t = new string[](7);
        t[0] = "x";
        t[1] = "repost";
        t[2] = "retweet";
        t[3] = "quote";
        t[4] = "twitter";
        t[5] = "kol";
        t[6] = "tweet";
        return t;
    }

    function version() external pure override returns (string memory) {
        return "1.0";
    }

    function protocolFee() external view returns (uint96) {
        return PROTOCOL_FEE;
    }

    function protocolFeePolicy() external view override returns (string memory) {
        uint256 fee = uint256(PROTOCOL_FEE);
        return string(abi.encodePacked(
            FeeFormat.formatHuman(feeToken, fee), " per deal (raw ", FeeFormat.toStr(fee), "). ",
            "Locked at createDeal(), charged on Poster accept(), refunded if cancelDeal() is called before accept()."
        ));
    }

    // ===================== Verification Query =====================

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
        if (d.sponsor == address(0)) revert InvalidParams();

        specParams = abi.encode(d.tweet_id, d.poster);

        return (d.verifier, uint256(d.verifierFee), d.signatureDeadline, d.verifierSignature, specParams);
    }

    // ===================== Instruction =====================

    function instruction() external pure override returns (string memory) {
        return
            "# Sponsored Repost on X (Twitter)\n\n"
            "A USDC-settled contract where a Sponsor commissions a Poster to promote a tweet on X.\n\n"
            "- **Sponsor**: Specifies a tweet and deposits USDC reward.\n"
            "- **Poster**: Retweets or quotes the tweet on X.\n"
            "- Once Sponsor manually confirms, or the verifier auto-verifies, Poster claims the reward.\n\n"
            "> **Amounts**: USDC raw `uint96` integers, decimals=6 (e.g. `1500000` = 1.5 USDC). Token address via `feeToken()`.\n\n"
            "## Before createDeal\n\n"
            "> **Poster binding**: Poster must have completed Twitter binding on the platform.\n\n"
            "### 1. Price Negotiation (off-chain)\n\n"
            "Sponsor and Poster negotiate the reward (net amount) via the platform message channel:\n\n"
            "- **Sponsor (Offer)**: Self-assess the Poster's value by follower count, engagement rate, content fit, etc.\n"
            "- **Poster (Evaluate)**: Self-judge whether the price and the tweet content are acceptable; counter-offer if not.\n"
            "- Both parties may iterate on the price with multiple rounds of counter-offers.\n"
            "- Either party may walk away if the price is unacceptable.\n"
            "- Outcome: an agreed `reward` (Poster's net income) and `tweet_id`.\n"
            "- Constraint: `reward >= verifierFee` -- keeps dispute cost bounded by deal value so either side has incentive to push verification through.\n\n"
            "### 2. On-chain Preparation\n\n"
            "With price agreed, Sponsor prepares funds and signature:\n\n"
            "1. Call `protocolFee()` to get the protocol fee, then compute `grossAmount = reward + protocolFee`.\n"
            "2. Ensure USDC allowance covers `grossAmount + verifierFee`. Rationale:\n"
            "   - `grossAmount` (reward + protocolFee) is locked in the contract at `createDeal`.\n"
            "   - `verifierFee` is **not** locked at `createDeal`; it is pulled later from whoever calls `requestVerification` on the dispute path (typically Sponsor). That party must still hold `verifierFee` balance + allowance at that moment, so Sponsor approves it up front for convenience.\n"
            "3. Obtain verifier signature via `request_sign`, passing `{tweet_id, reposter_address}` (the Poster's address). The returned `sig` is bound to that exact address along with `fee` and `deadline`.\n\n"
            "Ready: `sig`, `verifierFee`, `deadline`, and sufficient USDC allowance -- call `createDeal`.\n\n"
            "## createDeal Parameters\n\n"
            "| Parameter | Type | Description |\n"
            "|------|------|------|\n"
            "| poster | address | Poster address. |\n"
            "| grossAmount | uint96 | Negotiated reward + protocol fee (USDC raw value). See Before createDeal. |\n"
            "| verifier | address | Verifier contract address |\n"
            "| verifierFee | uint96 | Verification fee (USDC raw value). Must satisfy `verifierFee <= reward`. |\n"
            "| deadline | uint256 | Verifier signature validity (Unix seconds) |\n"
            "| sig | bytes | Verifier EIP-712 signature attesting to the committed verification data (tweet_id, poster, fee, deadline) |\n"
            "| tweet_id | string | Tweet ID to be reposted |\n\n"
            "> On creation, `grossAmount` is transferred to the contract in full; the protocol fee is only collected after Poster calls `accept`. If Poster does not accept and the deal is cancelled, both protocol fee and reward are refunded to Sponsor.\n\n"
            "## dealStatus Action Guide\n\n"
            "After `createDeal`, record the returned `dealIndex`; drive the rest of the flow by reading `dealStatus(dealIndex)` and acting per the table below.\n\n"
            "| Code | Status | Sponsor's Action | Poster's Action |\n"
            "|----|------|------|------|\n"
            "| 0 | WaitingAccept | Wait for Poster | Review the deal, then `accept(dealIndex)` |\n"
            "| 1 | AcceptTimedOut | `cancelDeal(dealIndex)` | -- |\n"
            "| 2 | WaitingClaim | Wait for Poster | Retweet or quote the tweet, then `claimDone(dealIndex)` |\n"
            "| 3 | ClaimTimedOut | `triggerTimeout(dealIndex)` | -- |\n"
            "| 4 | WaitingConfirm | `confirmAndPay(dealIndex)` or `requestVerification(dealIndex, 0)` | Wait for Sponsor, or `requestVerification(dealIndex, 0)` if Sponsor is unresponsive |\n"
            "| 5 | ConfirmTimedOut | -- | `triggerTimeout(dealIndex)` |\n"
            "| 6 | Verifying | Wait | Wait |\n"
            "| 7 | VerifierTimedOut | `resetVerification(dealIndex, 0)` | `resetVerification(dealIndex, 0)` |\n"
            "| 8 | Settling | `proposeSettlement(dealIndex, amountToSponsor)` | `proposeSettlement(dealIndex, amountToSponsor)` |\n"
            "| 9 | SettlementProposed | `confirmSettlement(dealIndex, expectedVersion)` to accept counterparty's proposal, or update own proposal | `confirmSettlement(dealIndex, expectedVersion)` to accept counterparty's proposal, or update own proposal |\n"
            "| 10 | SettlementTimedOut | `triggerSettlementTimeout(dealIndex)` | `triggerSettlementTimeout(dealIndex)` |\n"
            "| 11 | Completed | -- | -- |\n"
            "| 12 | Violated | Non-violator: `withdraw(dealIndex)` | Non-violator: `withdraw(dealIndex)` |\n"
            "| 13 | Cancelled | -- | -- |\n"
            "| 14 | Forfeited | -- (funds seized to protocol) | -- (funds seized to protocol) |\n"
            "| 255 | NotFound | Deal does not exist | Deal does not exist |\n\n"
            "## Notes\n\n"
            "### Timeouts\n\n"
            "30 minutes per stage (Settling: 12 hours). The settlement phase is entered only on inconclusive verification or verifier timeout. Use `timeRemaining(dealIndex)` to query remaining seconds.\n\n"
            "### Verification flow (code 4)\n\n"
            "1. `requestVerification(dealIndex, 0)`\n"
            "2. **Must** notify the verifier to begin verification\n"
            "3. Passed: auto-payment to Poster; failed: Poster is in breach. On pass/fail the verification fee is paid to the verifier (non-refundable). On inconclusive (result=0) or verifier timeout (`resetVerification`), the verification fee is refunded to the requester.\n"
            "4. On `WaitingConfirm`, Sponsor has NOT yet seen the specific repost on-chain (the deal does not carry a repost id). If Sponsor wants evidence, Sponsor must call `requestVerification` -- the verifier will report matching repost details off-chain via the platform message channel.\n\n"
            "### Settlement (code 8/9/10)\n\n"
            "Each party maintains their own proposal independently. In `proposeSettlement(dealIndex, amountToSponsor)`, amountToSponsor is **the amount Sponsor receives** (x10^6); the remainder goes to Poster. Call `settlement(dealIndex)` to query proposals and their version numbers. `confirmSettlement(dealIndex, expectedVersion)` accepts the counterparty's proposal; pass the counterparty's version from `settlement()` as expectedVersion.\n\n"
            "After 12 hours, new proposals are blocked. If any proposal exists, a 1-hour grace period allows `confirmSettlement` only. After the grace period (or immediately if no proposals), `triggerSettlementTimeout` forfeits all funds to the protocol.\n\n"
            "---\n\n"
            "**Both repost (retweet) and quote count as valid.**\n\n"
            "**Sponsor owns Poster selection and tracks sponsorship history to avoid repeat abuse.**\n";
    }

    // ===================== Status Query =====================

    /// @notice Platform-level unified deal phase
    /// @dev 0=NotFound, 1=Pending, 2=Active, 3=Success, 4=Failed, 5=Cancelled
    function phase(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.sponsor == address(0)) return 0; // NotFound

        uint8 s = d.status;
        if (s == WAITING_ACCEPT) return 1;   // Pending
        if (s == COMPLETED) return 3;         // Success
        if (s == VIOLATED) return 4;          // Failed
        if (s == FORFEITED) return 4;         // Failed
        if (s == CANCELLED) return 5;         // Cancelled
        return 2; // Active（WAITING_CLAIM, WAITING_CONFIRM, VERIFYING, SETTLING）
    }

    /// @notice Unified business status code — independent of msg.sender, same result for any caller
    /// @dev Storage base value combined with runtime conditions (timeout, proposals) derives full status codes 0-14, 255
    function dealStatus(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.sponsor == address(0)) return NOT_FOUND;

        uint8 s = d.status;

        if (s == WAITING_ACCEPT) {
            return _isStageTimedOut(dealIndex) ? ACCEPT_TIMED_OUT : WAITING_ACCEPT;
        }
        if (s == WAITING_CLAIM) {
            return _isStageTimedOut(dealIndex) ? CLAIM_TIMED_OUT : WAITING_CLAIM;
        }
        if (s == WAITING_CONFIRM) {
            return _isStageTimedOut(dealIndex) ? CONFIRM_TIMED_OUT : WAITING_CONFIRM;
        }
        if (s == VERIFYING) {
            if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) {
                return VERIFIER_TIMED_OUT;
            }
            return VERIFYING;
        }
        if (s == SETTLING) {
            bool hasProposal = settlementBySponsor[dealIndex].proposer != address(0)
                            || settlementByPoster[dealIndex].proposer != address(0);
            uint256 settlingDeadline = uint256(d.stageTimestamp) + SETTLING_TIMEOUT;
            if (hasProposal) {
                if (block.timestamp > settlingDeadline + CONFIRM_GRACE_PERIOD) return SETTLEMENT_TIMED_OUT;
            } else {
                if (block.timestamp > settlingDeadline) return SETTLEMENT_TIMED_OUT;
            }
            if (hasProposal) return SETTLEMENT_PROPOSED;
            return SETTLING;
        }

        return s;
    }

    /// @notice Whether a deal with the given index exists
    function dealExists(uint256 dealIndex) external view override returns (bool) {
        return deals[dealIndex].sponsor != address(0);
    }
}
