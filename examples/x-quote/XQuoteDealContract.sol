// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealBase.sol";
import "./IVerifier.sol";
import "./XQuoteVerifierSpec.sol";
import "./IERC20.sol";
import "./Initializable.sol";
import "./MetaTxMixin.sol";
import "./BindingAttestation.sol";


/// @title XQuoteDealContract - X Quote Tweet Deal Contract
/// @notice Single contract managing all deals. feeToken set via setFeeToken() once (cross-chain unified address).
/// @dev USDC approve · Packed storage · Custom errors · Direct payout
///      Unified dealStatus — status field stores dealStatus base value directly, no internal State enum
///
///      Deal flow overview:
///      1. A creates deal, deposits USDC (reward + protocolFee), specifying B and Verifier
///      2. B accepts deal (protocolFee sent to FeeCollector at this point)
///      3. B quotes the tweet on X, then calls claimDone to submit quote_tweet_id
///      4. A manually confirms payment, or requests Verifier auto-verification
///      5. If verification is inconclusive or Verifier times out, enters settlement phase
contract XQuoteDealContract is DealBase, Initializable, MetaTxMixin("XQuoteDeal", "1") {

    // ===================== Errors =====================

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
        address partyA;                   // 20 bytes — Party A address (initiator/payer)
        uint48  stageTimestamp;           // 6 bytes  — Current stage start time
        uint8   status;                   // 1 byte   — dealStatus base value
        bool    isRequesterA;             // 1 byte   — Whether verification requester is A (for timeout refund)
        // Slot 2
        address partyB;                   // 20 bytes — Party B address (executor/quoter)
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
        string  tweet_id;                 // Tweet ID to be quoted
        uint64  quoter_user_id;           // Bound X/Twitter immutable user_id
        string  quote_tweet_id;           // B's quote tweet ID, set by claimDone
        bytes   verifierSignature;        // EIP-712 signature (slot 0, 65 bytes)
    }

    /// @dev Settlement proposal, only used in Settling state
    struct Settlement {
        address proposer;     // 20 bytes — Proposer
        uint96  amountToA;    // 12 bytes — Proposed amount for A (remainder goes to B)
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
    BindingAttestation public immutable BINDING_ATTESTATION;

    // ===================== Storage =====================

    uint256 private _lock = 1;

    mapping(uint256 => Deal) internal deals;
    mapping(uint256 => Settlement) internal settlementByA;
    mapping(uint256 => Settlement) internal settlementByB;

    // ===================== BySig TYPEHASH Constants =====================

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

    // ===================== Modifiers =====================

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

    // ===================== Constructor =====================

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

    // ===================== Create Deal =====================

    /// @notice Create a deal (requires pre-approved USDC)
    /// @param quoterUserId B's Twitter immutable user_id
    /// @param bindingSig Platform-issued binding attestation signature for B
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

    /// @notice Create deal (gasless BySig version)
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
        // --- Validation ---
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

        // Verify B's Binding Attestation
        if (!BINDING_ATTESTATION.verify(partyB, quoterUserId, bindingSig)) revert InvalidBindingSignature();

        _verifyVerifierSignature(verifier, tweet_id, quoterUserId, verifierFee, deadline, sig);

        // --- Transfer USDC to escrow ---
        if (!IERC20(feeToken).transferFrom(sender, address(this), grossAmount)) revert TransferFailed();

        // --- Create deal record ---
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

    // ===================== Core Flow =====================

    /// @notice B accepts the deal
    function accept(uint256 dealIndex)
        external
        nonReentrant
    {
        _acceptCore(msg.sender, dealIndex);
    }

    /// @notice B accepts the deal (gasless BySig version)
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

    /// @notice B declares the quote is done, submits quote_tweet_id
    function claimDone(uint256 dealIndex, string calldata quote_tweet_id)
        external
        nonReentrant
    {
        _claimDoneCore(msg.sender, dealIndex, quote_tweet_id);
    }

    /// @notice B declares the quote is done (gasless BySig version)
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

    /// @notice A manually confirms and pays B directly (skipping verification)
    function confirmAndPay(uint256 dealIndex)
        external
        nonReentrant
    {
        _confirmAndPayCore(msg.sender, dealIndex);
    }

    /// @notice A manually confirms and pays B (gasless BySig version)
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

    // ===================== Cancel (WAITING_ACCEPT → CANCELLED) =====================

    /// @notice A cancels a deal that B has not yet accepted (WAITING_ACCEPT + timed out)
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

    // ===================== Verification =====================

    /// @notice Trader triggers verification (caller pays fee via approve)
    function requestVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        nonReentrant
        override
    {
        _requestVerificationCore(msg.sender, dealIndex, verificationIndex);
    }

    /// @notice Trader triggers verification (gasless BySig version)
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

        // CEI: state changes first
        d.status = VERIFYING;
        d.isRequesterA = (sender == d.partyA);
        d.verificationTimestamp = uint48(block.timestamp);

        emit VerificationRequested(dealIndex, verificationIndex, verifier);

        if (!IERC20(feeToken).transferFrom(sender, address(this), fee)) revert TransferFailed();
    }

    /// @notice Verifier submits verification result
    /// @dev result > 0 → passed, pay B
    ///      result < 0 → failed, B violated
    ///      result == 0 → inconclusive, enter settlement
    function onVerificationResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason) external nonReentrant override onlySlot0(verificationIndex) {
        Deal storage d = deals[dealIndex];

        if (msg.sender != d.verifier) revert NotVerifier();
        if (d.status != VERIFYING) revert InvalidStatus();
        if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) revert AlreadyTimedOut();

        // Clear verification timestamp
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

        // --- Events ---
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

        // --- Interactions: all transfers last ---
        if (vFee > 0) {
            if (result == 0) {
                // inconclusive — verifier did not complete work, refund verifierFee to requester
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
        if (sender != d.partyA && sender != d.partyB) revert NotAorB();
        if (block.timestamp <= uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT)
            revert VerificationNotTimedOut();

        address requester = d.isRequesterA ? d.partyA : d.partyB;
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

    /// @notice Propose a settlement: amountToA is the amount for A (remainder goes to B)
    /// @dev Dual-proposal mode: A/B each maintain independent proposals, no overwriting. New proposals blocked after 12h.
    ///      Version incremented on each proposal; expectedVersion required on confirm to prevent front-running.
    function proposeSettlement(uint256 dealIndex, uint96 amountToA)
        external
        nonReentrant
    {
        _proposeSettlementCore(msg.sender, dealIndex, amountToA);
    }

    /// @notice Propose settlement (gasless BySig version)
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

    /// @notice Confirm counterparty's settlement proposal
    /// @dev Within 12h: normal confirm; 12h~13h grace period: can still confirm existing proposals (but not create new ones); after 13h: locked.
    /// @param expectedVersion Expected proposal version, prevents front-running
    function confirmSettlement(uint256 dealIndex, uint256 expectedVersion)
        external
        nonReentrant
    {
        _confirmSettlementCore(msg.sender, dealIndex, expectedVersion);
    }

    /// @notice Confirm counterparty's settlement proposal (gasless BySig version)
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

        // Get counterparty's proposal
        Settlement storage stl = (sender == d.partyA) ? settlementByB[dealIndex] : settlementByA[dealIndex];
        if (stl.proposer == address(0)) revert InvalidSettlement();
        if (stl.version != expectedVersion) revert VersionMismatch();

        // Timeout check: within 12h OK; 12h~13h grace OK; after 13h locked
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

    /// @notice Settlement timeout, funds seized to FeeCollector
    /// @dev When proposals exist, must wait until grace period (13h) expires; when no proposals, triggers after 12h.
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

    // ===================== Timeout =====================

    /// @notice Trigger timeout for current stage
    /// @dev WAITING_CLAIM timeout: B didn't claimDone → B violated
    ///      WAITING_CONFIRM timeout: A didn't confirm → auto-pay B
    function triggerTimeout(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        if (!_isStageTimedOut(dealIndex)) revert NotTimedOut();

        uint8 s = d.status;

        if (s == WAITING_CLAIM) {
            // B didn't claimDone → B violated
            if (msg.sender != d.partyA) revert NotPartyA();
            d.status = VIOLATED;
            d.violator = d.partyB;
            _emitViolated(dealIndex, d.partyB, "claim timeout");
            _emitStatusChanged(dealIndex, VIOLATED);
            _emitPhaseChanged(dealIndex, 4); // → Failed

        } else if (s == WAITING_CONFIRM) {
            // A didn't confirm → auto-pay B
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

    /// @notice Withdraw funds after violation
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

    // ===================== Internal Helpers =====================

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
            bool hasProposal = settlementByA[dealIndex].proposer != address(0)
                            || settlementByB[dealIndex].proposer != address(0);
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

    /// @notice Check if deal stage has timed out
    function isTimedOut(uint256 dealIndex) external view returns (bool) {
        return _isStageTimedOut(dealIndex);
    }

    // ===================== Standard Identity =====================

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
        if (d.partyA == address(0)) revert InvalidParams();

        specParams = abi.encode(d.tweet_id, d.quoter_user_id, d.quote_tweet_id);

        return (d.verifier, uint256(d.verifierFee), d.signatureDeadline, d.verifierSignature, specParams);
    }

    // ===================== Instruction =====================

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

    // ===================== Status Query =====================

    /// @notice Platform-level unified deal phase
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

    /// @notice Unified business status code — independent of msg.sender, same result for any caller
    /// @dev Storage base value combined with runtime conditions (timeout, proposals) derives full status codes 0-14, 255
    function dealStatus(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.partyA == address(0)) return NOT_FOUND;

        uint8 s = d.status;

        // WAITING_ACCEPT (0) → may time out (1)
        if (s == WAITING_ACCEPT) {
            return _isStageTimedOut(dealIndex) ? ACCEPT_TIMED_OUT : WAITING_ACCEPT;
        }

        // WAITING_CLAIM (2) → may time out (3)
        if (s == WAITING_CLAIM) {
            return _isStageTimedOut(dealIndex) ? CLAIM_TIMED_OUT : WAITING_CLAIM;
        }

        // WAITING_CONFIRM (4) → may time out (5)
        if (s == WAITING_CONFIRM) {
            return _isStageTimedOut(dealIndex) ? CONFIRM_TIMED_OUT : WAITING_CONFIRM;
        }

        // VERIFYING (6) → may verifier time out (7)
        if (s == VERIFYING) {
            if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) {
                return VERIFIER_TIMED_OUT;
            }
            return VERIFYING;
        }

        // SETTLING (8) → may have proposal (9) or time out (10)
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

        // Terminal states: COMPLETED (11), VIOLATED (12), CANCELLED (13), FORFEITED (14)
        return s;
    }

    /// @notice Whether a deal with the given index exists
    function dealExists(uint256 dealIndex) external view override returns (bool) {
        return deals[dealIndex].partyA != address(0);
    }
}
