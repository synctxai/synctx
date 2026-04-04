// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealBase.sol";
import "./IVerifier.sol";
import "./XFollowVerifierSpec.sol";
import "./IERC20.sol";
import "./MetaTxMixin.sol";
import "./BindingAttestation.sol";


/// @title XFollowCampaign - X Paid Follow Campaign Sub-contract
/// @notice Created by XFollowFactory via EIP-1167 clone. Each instance = one campaign.
///         A deposits budget, any user authenticated via Binding Attestation can follow and claim a fixed reward.
///         Each B's claim() creates a new dealIndex. Fully automated, no negotiation needed.
/// @dev Lifecycle: OPEN → CLOSED
///      No constructor — all state is set via initialize() in one call (clone compatible).
contract XFollowCampaign is DealBase, MetaTxMixin("", "") {

    /// @dev Lock implementation against initialize() — clones are unaffected.
    constructor() {
        _initialized = true;
    }

    // ===================== Errors =====================

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

    // ===================== Events =====================

    /// @notice Verifier timeout event, for platform to index verifier reliability
    event VerifierTimeout(uint256 indexed dealIndex, address indexed verifier);

    // ===================== dealStatus Constants (per-claim) =====================
    //
    //   Storage base value          dealStatus derived value
    //   ─────────────               ──────────────────
    //   VERIFYING        (0)        → VERIFIER_TIMED_OUT (1)
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

    // ===================== campaignStatus Constants =====================

    uint8 constant OPEN                 = 1;
    uint8 constant CLOSED               = 2;

    // ===================== Types =====================

    struct Claim {
        address claimer;             // B's address
        uint48  timestamp;           // Claim creation time
        uint8   status;              // VERIFYING / COMPLETED / REJECTED / TIMED_OUT / INCONCLUSIVE
        uint64  follower_user_id;    // Verified via Binding Attestation at claim time
    }

    // ===================== Constants =====================

    uint256 public constant VERIFICATION_TIMEOUT = 30 minutes;
    uint8 public constant MAX_FAILURES = 3;

    // ===================== Initialization Guard & Reentrancy Lock =====================

    bool private _initialized;
    uint256 private _lock = 1;

    // ===================== Config (set by factory during initialize) =====================

    address public feeToken;
    address public feeCollector;
    uint96  public protocolFee;
    address public requiredSpec;
    BindingAttestation public bindingAttestation;

    // ===================== Campaign Storage =====================

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

    /// @notice Verifier timeout count (on-chain credit signal)
    uint32  public verifierTimeoutCount;

    // ===================== Per-Claim Storage =====================

    mapping(uint256 => Claim) internal claims;
    mapping(address => bool)  public claimedAddress;
    mapping(uint64  => uint8) public claimedUserId;          // 0=unclaimed 1=verifying 2=claimed
    mapping(address => uint8) public failCount;
    mapping(address => uint256) internal pendingClaimIndex;  // B → current pending dealIndex

    // ===================== BySig TYPEHASH Constants =====================

    bytes32 private constant _CLAIM_TYPEHASH = keccak256(
        "ClaimBySig(uint64 userId,bytes32 bindingSigHash,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    // ===================== Modifiers =====================

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

    // ===================== Initialization (replaces constructor, clone compatible) =====================

    /// @notice Called atomically by XFollowFactory after clone, initializes all parameters once
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

        // MetaTxMixin initialization (clone path)
        _initMetaTxDomain("XFollowCampaign", "1");

        // Config
        feeToken = feeToken_;
        feeCollector = feeCollector_;
        protocolFee = protocolFee_;
        requiredSpec = requiredSpec_;
        bindingAttestation = BindingAttestation(bindingAttestation_);

        // Campaign parameter validation
        if (rewardPerFollow_ == 0) revert InvalidParams();
        if (deadline_ <= block.timestamp) revert InvalidParams();
        if (verifier_ == address(0)) revert InvalidParams();
        if (partyA_ == verifier_) revert InvalidParams();
        if (verifier_.code.length == 0) revert VerifierNotContract();
        if (sig_.length == 0) revert InvalidVerifierSignature();
        if (sigDeadline_ < uint256(deadline_) + VERIFICATION_TIMEOUT) revert SignatureExpired();
        if (grossAmount_ < rewardPerFollow_ + verifierFee_ + protocolFee_) revert InsufficientBudget();
        if (target_user_id_ == 0) revert InvalidParams();

        // Verify Verifier signature
        _verifyVerifierSignature(verifier_, target_user_id_, verifierFee_, sigDeadline_, sig_);

        // Set up campaign (USDC already transferFrom'd by factory to this contract)
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

    // ===================== Claim (each claim = one dealIndex) =====================

    /// @notice B claims follow reward. Submits Binding Attestation to prove identity.
    ///         claimedUserId states: 0=claimable, 1=verifying (locked), 2=successfully claimed (permanently locked).
    ///         Failed/inconclusive auto-resets to 0; timeout requires calling resetVerification() first before retry.
    /// @param userId B's Twitter immutable user_id
    /// @param bindingSig Platform-issued binding attestation signature
    function claim(uint64 userId, bytes calldata bindingSig) external nonReentrant returns (uint256 dealIndex) {
        return _claimCore(msg.sender, userId, bindingSig);
    }

    /// @notice B claims follow reward (gasless BySig version)
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
        // Check and possibly trigger auto-close
        _checkAndClose();
        if (campaignStatus != OPEN) revert CampaignNotOpen();

        if (claimedAddress[sender]) revert AlreadyClaimed();
        if (claimedUserId[userId] != 0) revert AlreadyClaimed();
        if (failCount[sender] >= MAX_FAILURES) revert MaxFailures();

        // Check for pending claim
        if (_hasPendingClaim(sender)) revert PendingClaim();

        // Verify Binding Attestation
        if (!bindingAttestation.verify(sender, userId, bindingSig)) revert InvalidBindingSignature();
        uint64 followerUserId = userId;

        uint96 cost = _claimCost();
        if (budget < cost) {
            // Budget exhausted, auto-close
            if (pendingClaims == 0) {
                campaignStatus = CLOSED;
                _emitServiceModeChanged(MODE_CLOSED);
            }
            revert BudgetExhausted();
        }

        // Lock fees
        budget -= cost;

        // Create claim (= dealIndex)
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

    // ===================== Verification Result Callback =====================

    /// @notice Verifier submits verification result
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
            // Passed: pay B
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
            // Failed: reward + protocolFee refunded to budget, only verifierFee paid out, B violated
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
            // Inconclusive: full refund to budget, no fees deducted
            c.status = INCONCLUSIVE;
            claimedUserId[c.follower_user_id] = 0;
            budget += reward + vFee + pFee;

            _emitStatusChanged(dealIndex, INCONCLUSIVE);
            _emitPhaseChanged(dealIndex, 4); // → Failed
        }

        // Check if should auto-close
        _checkAndClose();
    }

    // ===================== Verification Timeout Reset =====================

    /// @notice Reset claim after verifier timeout, full refund to budget.
    ///         Anyone can call (permissionless cleanup).
    ///         After reset, claimedUserId and pendingClaimIndex are unlocked, B can re-claim().
    ///         Failed (result<0) and inconclusive (result==0) are auto-cleaned by onVerificationResult, no manual reset needed.
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

    // ===================== Campaign Closure =====================

    /// @notice A manually closes campaign, prevents new claims, does not affect existing pending claims
    function closeCampaign() external onlyA {
        if (campaignStatus != OPEN) revert CampaignNotOpen();
        campaignStatus = CLOSED;
        _emitServiceModeChanged(MODE_CLOSED);
    }

    /// @notice When CLOSED and no pending claims, A withdraws remaining budget
    function withdrawRemaining() external onlyA nonReentrant {
        if (campaignStatus != CLOSED) revert NotClosed();
        if (pendingClaims > 0) revert PendingClaims();
        if (budget == 0) revert NoFunds();

        uint96 amt = budget;
        budget = 0;
        if (!IERC20(feeToken).transfer(partyA, amt)) revert TransferFailed();
    }

    // ===================== Internal Helpers =====================

    function _claimCost() internal view returns (uint96) {
        return rewardPerFollow + verifierFee + protocolFee;
    }

    function _checkAndClose() internal {
        if (campaignStatus != OPEN) return;
        if (block.timestamp > deadline) {
            campaignStatus = CLOSED;
            _emitServiceModeChanged(MODE_CLOSED);
        } else if (budget < _claimCost() && pendingClaims == 0) {
            campaignStatus = CLOSED;
            _emitServiceModeChanged(MODE_CLOSED);
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

    // ===================== Query Functions =====================

    /// @notice Total cost per claim
    function claimCost() external view returns (uint96) {
        return _claimCost();
    }

    /// @notice Remaining claimable slots
    function remainingSlots() external view returns (uint256) {
        uint96 cost = _claimCost();
        if (cost == 0) return 0;
        return uint256(budget) / uint256(cost);
    }

    /// @notice Whether a given address + userId can claim (including binding check)
    function canClaim(address addr, uint64 userId, bytes calldata bindingSig) external view returns (bool) {
        if (campaignStatus != OPEN) return false;
        if (block.timestamp > deadline) return false;
        if (budget < _claimCost()) return false;
        if (claimedAddress[addr]) return false;
        if (claimedUserId[userId] != 0) return false;
        if (failCount[addr] >= MAX_FAILURES) return false;
        if (_hasPendingClaim(addr)) return false;
        if (!bindingAttestation.verify(addr, userId, bindingSig)) return false;
        return true;
    }

    /// @notice Address failure count
    function failures(address addr) external view returns (uint8) {
        return failCount[addr];
    }

    // ===================== IDeal Implementation =====================

    function name() external pure override returns (string memory) {
        return "X(Twitter) Follow Campaign";
    }

    function description() external pure override returns (string memory) {
        return "Pay fixed USDC reward per X(Twitter) follow. 1-to-many campaign, auto-verified. Twitter binding required.";
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

    /// @notice claim() auto-triggers verification internally; external calls always revert
    function requestVerification(uint256, uint256) external pure override {
        revert("use claim() instead");
    }

    /// @notice Platform-level unified deal phase (per-claim)
    function phase(uint256 dealIndex) external view override returns (uint8) {
        Claim storage c = claims[dealIndex];
        if (c.claimer == address(0)) return 0; // NotFound
        if (c.status == VERIFYING) return 2;   // Active
        if (c.status == COMPLETED) return 3;   // Success
        return 4;                               // Failed (REJECTED / TIMED_OUT / INCONCLUSIVE)
    }

    /// @notice Business-level status code (per-claim, with derived states)
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

    /// @notice Contract-level operating state: OPEN → OPENING, CLOSED → CLOSED
    function serviceMode() external view override returns (uint8) {
        return campaignStatus == OPEN ? MODE_OPENING : MODE_CLOSED;
    }

    function instruction() external view override returns (string memory) {
        return
            "# X(Twitter) Follow Campaign\n\n"
            "Pay fixed USDC reward per follow to a target account on Twitter. 1-to-many campaign model.\n\n"
            "- **A (Creator)**: Deposits USDC budget, sets target account and reward per follow\n"
            "- **B (Follower)**: Follows the target account on Twitter, claims reward\n"
            "- Verification is fully automatic; B receives reward on pass\n\n"
            "| Item | Value |\n"
            "|----|----|\n"
            "| Token | USDC (decimals=6), address via `feeToken()` |\n"
            "| Amount | Raw value x10^6, e.g. 1.5 USDC = `1500000` |\n\n"
            "## Campaign Lifecycle\n\n"
            "OPEN -> CLOSED\n\n"
            "- **OPEN**: Campaign goes live immediately after initialization. Params are locked, anyone with Twitter binding can claim().\n"
            "- **CLOSED**: A can call `closeCampaign()` at any time to stop the campaign. Also auto-triggered on deadline or budget exhaustion.\n\n"
            "## For Followers (B)\n\n"
            "1. Complete Twitter verification on Platform and obtain the Twitter binding signature via `twitter-binding-sig`\n"
            "2. Follow the target account on Twitter\n"
            "3. Call `claim(userId, bindingSig)` — userId is your Twitter immutable user_id (uint64), bindingSig is the Twitter binding signature (bytes)\n"
            "4. **Must** notify the verifier to begin verification (verifier address: read `verifier()`)\n"
            "5. Wait for verification result\n\n"
            "**Pre-flight**: Call `canClaim(addr, userId, bindingSig)` before claim() to check eligibility (address + userId dedup + binding attestation + budget).\n\n"
            "## Costs\n\n"
            "B pays nothing. All fees (reward + verifierFee + protocolFee) come from A's budget.\n"
            "Query `claimCost()` for per-claim cost, `remainingSlots()` for available claims.\n\n"
            "## Fee Policy\n\n"
            "- Successful claim: reward to B, verifierFee to Verifier, protocolFee to Developer.\n"
            "- Failed claim (not following): only verifierFee deducted, reward + protocolFee refunded to budget.\n"
            "- Inconclusive (API error): full refund to budget.\n\n"
            "## Failure Policy\n\n"
            "Failed claims (not following) increment failCount. After 3 failures, banned from this campaign.\n"
            "Inconclusive results (API errors) do not count as failures.\n\n"
            "## dealStatus Action Guide (per-claim)\n\n"
            "Each `claim()` creates a new dealIndex. `dealStatus(dealIndex)` returns the claim's current status:\n\n"
            "| Code | Status | Action |\n"
            "|----|------|------|\n"
            "| 0 | Verifying | Wait for automatic verification result |\n"
            "| 1 | VerifierTimedOut | Anyone: `resetVerification(dealIndex, 0)` to refund budget |\n"
            "| 2 | Completed | Reward paid to B. No action needed |\n"
            "| 3 | Rejected | B was not following. No action (verifierFee deducted from budget) |\n"
            "| 4 | TimedOut | Verification timed out and was reset. Budget refunded |\n"
            "| 5 | Inconclusive | API error. Budget fully refunded |\n"
            "| 255 | NotFound | Claim does not exist |\n\n"
            "> **Timeout**: 30 minutes from claim creation. Verification that exceeds this window can be reset by anyone via `resetVerification`.\n\n"
            "## Withdrawing Remaining Budget (A)\n\n"
            "1. Campaign must be CLOSED (A can call `closeCampaign()` at any time, or auto-triggered on deadline/budget exhaustion)\n"
            "2. If pending claims exist, wait for verification timeout (30 min), then call `resetVerification(dealIndex, 0)` for each\n"
            "3. Once `pendingClaims == 0`, call `withdrawRemaining()` to reclaim budget\n\n"
            "## Gasless Relay\n\n"
            "claim() optionally supports gasless relay via `claimBySig` (EIP-712 meta-transaction). "
            "The user signs, a relayer submits on-chain and pays gas.\n";
    }
}
