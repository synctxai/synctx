// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealContractBase.sol";
import "./IVerifier.sol";
import "./IVerifierSpec.sol";
import "./XQuoteVerifierSpec.sol";
import "./IUSDC.sol";


/// @title XQuoteDealContract - X Quote Tweet Deal Contract
/// @notice Single contract managing all deals. USDC address set via constructor.
/// @dev USDC approve · Packed storage · Custom errors · Direct payout
///      v4: VerifierSpec architecture — check() via spec contract, flat verification params
contract XQuoteDealContract is DealContractBase {

    // ===================== Errors =====================

    error NotPartyA();
    error NotPartyB();
    error NotVerifier();
    error NotAorB();
    error InvalidState();
    error NotTimedOut();
    error AlreadyTimedOut();
    error AlreadyRequested();
    error NotRequested();
    error NoFunds();
    error InvalidParams();
    error TransferFailed();
    error ViolatorCannot();
    error VerificationPending();
    error VerificationNotTimedOut();
    error ProposerCannotConfirm();
    error InvalidSettlement();
    error SettlementNotTimedOut();
    error FeeTooLow();
    error InvalidFeeCollector();
    error VerifierNotContract();
    error InvalidVerifierSign();
    error SignatureExpired();
    error InvalidVerificationIndex();
    error InvalidSpecAddress();
    error InsufficientAllowance();
    error InsufficientBalance();

    // ===================== Types =====================

    enum State {
        Created,     // 0 - A created & deposited, waiting B accept
        Accepted,    // 1 - B accepted, waiting B to quote & claimDone
        ClaimedDone, // 2 - B claims done, waiting A confirm
        Completed,   // 3 - done, funds sent to B
        Violated,    // 4 - terminated with violation
        Settling,    // 5 - verifier inconclusive/timeout, A/B negotiating
        Cancelled    // 6 - B didn't accept, A withdrew funds
    }

    /// @dev Packed into minimal storage slots.
    ///      Single-verification specialization (getRequiredSpecs().length == 1).
    ///      Verification fields correspond to the sole slot verificationIndex == 0.
    struct Deal {
        // Slot 1 (30/32 bytes)
        address partyA;                   // 20 bytes
        uint48  stageTimestamp;           // 6 bytes
        uint8   state;                    // 1 byte
        bool    verificationRequested;    // 1 byte
        bool    isRequesterA;             // 1 byte - who requested verification
        // Slot 2
        address partyB;                   // 20 bytes
        uint96  amount;                   // 12 bytes
        // Slot 3 — verifier info (slot 0)
        address verifier;                 // 20 bytes
        uint96  verifierFee;              // 12 bytes
        // Slot 4 (26/32 bytes — violator & verificationTimestamp are mutually exclusive)
        address violator;                 // 20 bytes
        uint48  verificationTimestamp;    // 6 bytes - when verification was requested
        // Slot 5 — signature deadline (slot 0)
        uint256 signatureDeadline;
        // Strings & bytes (dynamic, separate slots)
        string  tweet_id;                 // tweet ID (string)
        string  quoter_username;         // canonicalized: no leading @, lowercase
        string  quote_tweet_id;           // B's quote tweet ID, set by claimDone
        bytes   verifierSignature;        // EIP-712 signature (slot 0, 65 bytes)
    }

    /// @dev Settlement proposal, only used in Settling state
    struct Settlement {
        address proposer;     // 20 bytes — who proposed
        uint96  amountToA;    // 12 bytes — proposed amount for A (remainder goes to B)
    }

    // ===================== Constants =====================

    /// @notice Minimum allowed protocol fee (0.01 USDC with 6 decimals)
    uint96 public constant MIN_PROTOCOL_FEE = 10_000;

    /// @notice Timeout per stage
    uint256 public constant STAGE_TIMEOUT = 30 minutes;

    /// @notice Timeout for verifier to respond after verification requested
    uint256 public constant VERIFICATION_TIMEOUT = 30 minutes;

    /// @notice Timeout for A/B to finish settlement before funds are confiscated
    uint256 public constant SETTLING_TIMEOUT = 12 hours;

    /// @notice USDC token address
    address public immutable USDC;

    /// @notice Protocol fee collector contract
    address public immutable FEE_COLLECTOR;

    /// @notice Protocol fee collected after activation; refunded if cancelled before B accepts
    uint96 public immutable PROTOCOL_FEE;

    /// @notice Required VerifierSpec address for verification slot 0
    address public immutable REQUIRED_SPEC;

    // ===================== Storage =====================

    /// @notice All deals by index
    mapping(uint256 => Deal) internal deals;

    /// @notice Settlement proposals (only used in Settling state)
    mapping(uint256 => Settlement) internal settlements;

    // ===================== Business Events =====================

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

    // ===================== Modifiers =====================

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

    /// @dev This contract has exactly 1 verification slot (index 0)
    modifier onlySlot0(uint256 verificationIndex) {
        if (verificationIndex != 0) revert InvalidVerificationIndex();
        _;
    }

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

    // ===================== Create Deal =====================

    /// @notice Create a deal with pre-approved USDC
    /// @param partyB Counterparty (executor) address
    /// @param grossAmount Reward + protocol fee (USDC raw value)
    /// @param verifier Verifier contract address
    /// @param verifierFee Verification fee (USDC, 6 decimals)
    /// @param deadline Signature validity (Unix seconds)
    /// @param sig EIP-712 signature from verifier
    /// @param tweet_id Tweet ID to be quoted (string)
    /// @param quoter_username B's X username; leading @ is stripped and letters are lowercased
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
        // --- Validation ---
        if (grossAmount <= PROTOCOL_FEE) revert InvalidParams();
        if (verifierFee > grossAmount - PROTOCOL_FEE) revert InvalidParams();
        if (partyB == address(0)) revert InvalidParams();
        if (msg.sender == partyB) revert InvalidParams();

        if (verifier == address(0)) revert InvalidParams();
        if (msg.sender == verifier || partyB == verifier) revert InvalidParams();
        if (verifier.code.length == 0) revert VerifierNotContract();
        if (sig.length == 0) revert InvalidVerifierSign();
        if (deadline < block.timestamp) revert SignatureExpired();

        string memory canonicalUsername = _canonicalizeUsername(quoter_username);
        if (bytes(tweet_id).length == 0 || bytes(canonicalUsername).length == 0) revert InvalidParams();

        _verifyVerifierSignature(verifier, tweet_id, canonicalUsername, verifierFee, deadline, sig);

        // --- Transfer ---
        if (!IUSDC(USDC).transferFrom(msg.sender, address(this), grossAmount)) revert TransferFailed();

        // --- Create deal ---
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

    // ===================== Core Flow =====================

    /// @notice B accepts the deal
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

        if (!IUSDC(USDC).transfer(FEE_COLLECTOR, fee)) revert TransferFailed();

        emit ProtocolFeePaid(dealIndex, fee);
        emit DealFeeSplit(dealIndex, d.amount + fee, fee, d.amount);
        _recordActivated(dealIndex);
        emit DealAccepted(dealIndex);
        _emitStateChanged(dealIndex, uint8(State.Accepted));
    }

    /// @notice B declares the quote is done with a non-empty quote tweet id
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

    /// @notice A confirms and pays B directly
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

        if (!IUSDC(USDC).transfer(d.partyB, amt)) revert TransferFailed();

        emit DealCompleted(dealIndex, amt);
        _emitStateChanged(dealIndex, uint8(State.Completed));
        _recordEnd(dealIndex);
    }

    // ===================== Cancel (Created → Cancelled) =====================

    /// @notice A cancels a deal that B has not yet accepted (Created + timed out)
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
            if (!IUSDC(USDC).transfer(d.partyA, amt)) revert TransferFailed();
        }
    }

    // ===================== Verification =====================

    /// @notice Trader triggers verification (caller pays fee via approve)
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

        if (IUSDC(USDC).allowance(msg.sender, address(this)) < fee) revert InsufficientAllowance();
        if (IUSDC(USDC).balanceOf(msg.sender) < fee) revert InsufficientBalance();

        // Effects first (CEI pattern)
        d.verificationRequested = true;
        d.isRequesterA = (msg.sender == d.partyA);
        d.verificationTimestamp = uint48(block.timestamp);

        // 1. Caller pays verification fee to this contract (escrowed until verifier reports)
        if (!IUSDC(USDC).transferFrom(msg.sender, address(this), fee)) revert TransferFailed();

        // 2. Emit VerifyRequest event (verifier reads params via getVerificationParams)
        emit VerifyRequest(dealIndex, verificationIndex, verifier);
    }

    /// @notice Verifier submits verification result via reportResult → onReportResult
    function onReportResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata /* reason */) external override onlySlot0(verificationIndex) {
        Deal storage d = deals[dealIndex];

        // Security: only the designated verifier contract may call
        if (msg.sender != d.verifier) revert NotVerifier();
        if (d.state != uint8(State.ClaimedDone)) revert InvalidState();
        if (!d.verificationRequested) revert NotRequested();

        // Clear verification state (common to all branches)
        d.verificationRequested = false;
        d.verificationTimestamp = 0;

        uint96 vFee = d.verifierFee;

        // --- Effects: complete ALL state changes before any transfer (CEI) ---
        uint96 transferToB = 0;

        if (result > 0) {
            // Verification passed → pay B
            transferToB = d.amount;
            d.amount = 0;
            d.state = uint8(State.Completed);
        } else if (result < 0) {
            // Verification failed → B violated
            d.state = uint8(State.Violated);
            d.violator = d.partyB;
        } else {
            // result == 0 → inconclusive, enter Settling
            d.state = uint8(State.Settling);
            d.stageTimestamp = uint48(block.timestamp);
        }

        // --- Events ---
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

        // --- Interactions: all transfers last ---
        if (vFee > 0) {
            if (!IUSDC(USDC).transfer(msg.sender, vFee)) revert TransferFailed();
        }
        if (transferToB > 0) {
            if (!IUSDC(USDC).transfer(d.partyB, transferToB)) revert TransferFailed();
        }
    }

    // ===================== Verification Reset =====================

    /// @notice Reset verification after verifier timeout.
    ///         Refunds escrowed fee to requester, then enters Settling state.
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

        // --- Effects: all state changes first (CEI) ---
        d.verificationRequested = false;
        d.verificationTimestamp = 0;
        d.state = uint8(State.Settling);
        d.stageTimestamp = uint48(block.timestamp);

        // --- Events ---
        emit VerificationReset(dealIndex, verificationIndex, d.verifier);
        emit SettlingStarted(dealIndex);
        _emitStateChanged(dealIndex, uint8(State.Settling));

        // --- Interactions: transfer last ---
        if (vFee > 0) {
            if (!IUSDC(USDC).transfer(requester, vFee)) revert TransferFailed();
        }
    }

    // ===================== Settlement =====================

    /// @notice Propose a settlement: how much goes to A (remainder goes to B)
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

    /// @notice Confirm the other party's settlement proposal
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
            if (!IUSDC(USDC).transfer(d.partyA, toA)) revert TransferFailed();
        }
        if (toB > 0) {
            if (!IUSDC(USDC).transfer(d.partyB, toB)) revert TransferFailed();
        }

        emit SettlementConfirmed(dealIndex);
        _emitStateChanged(dealIndex, uint8(State.Completed));
        _recordEnd(dealIndex);
    }

    /// @notice Seize funds to fee collector if A/B fail to settle in time.
    /// @dev Anyone can trigger after timeout.
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
            if (!IUSDC(USDC).transfer(FEE_COLLECTOR, seized)) revert TransferFailed();
            emit FundsSeized(dealIndex, seized);
        }

        emit SettlementTimedOutSeized(dealIndex, seized);
        _emitStateChanged(dealIndex, uint8(State.Completed));
        _recordEnd(dealIndex);
    }

    // ===================== Timeout =====================

    /// @notice Trigger timeout for current stage
    function triggerTimeout(uint256 dealIndex) external {
        Deal storage d = deals[dealIndex];
        if (!_isTimedOut(dealIndex)) revert NotTimedOut();

        State s = State(d.state);

        if (s == State.Accepted) {
            // B didn't claimDone → violation
            if (msg.sender != d.partyA) revert NotPartyA();
            d.state = uint8(State.Violated);
            d.violator = d.partyB;
            _emitViolated(dealIndex, d.partyB);
            _emitStateChanged(dealIndex, uint8(State.Violated));
            _recordDispute(dealIndex);

        } else if (s == State.ClaimedDone) {
            // A didn't confirm → auto-pay B
            if (msg.sender != d.partyB) revert NotPartyB();
            if (d.verificationRequested) revert VerificationPending();
            uint96 amt = d.amount;
            d.amount = 0;
            d.state = uint8(State.Completed);
            if (!IUSDC(USDC).transfer(d.partyB, amt)) revert TransferFailed();
            emit DealCompleted(dealIndex, amt);
            _emitStateChanged(dealIndex, uint8(State.Completed));
            _recordEnd(dealIndex);

        } else {
            revert InvalidState();
        }
    }

    /// @notice Withdraw funds after violation
    function withdraw(uint256 dealIndex) external inState(dealIndex, State.Violated) {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.partyA && msg.sender != d.partyB) revert NotAorB();
        if (msg.sender == d.violator) revert ViolatorCannot();
        if (d.amount == 0) revert NoFunds();

        uint96 amt = d.amount;
        d.amount = 0;

        if (!IUSDC(USDC).transfer(msg.sender, amt)) revert TransferFailed();

        emit Withdrawn(dealIndex, msg.sender, amt);
    }

    // ===================== Internal Helpers =====================

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
            revert InvalidVerifierSign();
    }

    function _isTimedOut(uint256 dealIndex) internal view returns (bool) {
        Deal storage d = deals[dealIndex];
        uint256 timeout = d.state == uint8(State.Settling) ? SETTLING_TIMEOUT : STAGE_TIMEOUT;
        return block.timestamp > uint256(d.stageTimestamp) + timeout;
    }

    function _canonicalizeUsername(string memory value) internal pure returns (string memory) {
        bytes memory raw = bytes(value);
        uint256 start = 0;

        while (start < raw.length && raw[start] == 0x40) {
            unchecked {
                ++start;
            }
        }

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

    // ===================== View Functions =====================

    /// @notice Get remaining time in current stage
    function getTimeRemaining(uint256 dealIndex) external view returns (uint256) {
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

    /// @notice Check if verification has timed out
    function isVerificationTimedOut(uint256 dealIndex) external view returns (bool) {
        Deal storage d = deals[dealIndex];
        if (!d.verificationRequested) return false;
        return block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT;
    }

    /// @notice Get settlement proposal info
    function getSettlement(uint256 dealIndex) external view returns (
        address proposer,
        uint96  amountToA,
        uint96  amountToB
    ) {
        Settlement storage stl = settlements[dealIndex];
        uint96 total = deals[dealIndex].amount;
        return (stl.proposer, stl.amountToA, total - stl.amountToA);
    }

    /// @notice Check if deal is timed out
    function isTimedOut(uint256 dealIndex) external view returns (bool) {
        return _isTimedOut(dealIndex);
    }

    // ===================== Standard Identity =====================

    /// @notice Returns the contract name
    function contractName() external pure override returns (string memory) {
        return "X Quote Tweet Deal";
    }

    /// @notice Returns the contract description
    function description() external pure override returns (string memory) {
        return "Pay USDC to get a tweet quoted on X. 2-party (payer + quoter). On-chain verifier for auto-completion or manual confirm. 30min stage timeout, settlement on dispute.";
    }

    /// @notice Returns classification tags
    function getTags() external pure override returns (string[] memory) {
        string[] memory tags = new string[](2);
        tags[0] = "x";
        tags[1] = "quote";
        return tags;
    }

    /// @notice Returns the deal version
    function dealVersion() external pure override returns (string memory) {
        return "1.0";
    }

    /// @notice Protocol fee amount
    function protocolFee() external view override returns (uint96) {
        return PROTOCOL_FEE;
    }

    // ===================== Verification Query =====================

    /// @notice Returns the required spec address for each verification slot
    /// @dev This contract has exactly 1 verification slot (index 0)
    function getRequiredSpecs() external view override returns (address[] memory) {
        address[] memory specs = new address[](1);
        specs[0] = REQUIRED_SPEC;
        return specs;
    }

    /// @notice Returns full verification parameters for a given slot
    function getVerificationParams(uint256 dealIndex, uint256 verificationIndex)
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

    // ===================== Instruction =====================

    /// @notice Returns operation guide in Markdown format
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

    // ===================== Status Functions =====================

    /// @notice Universal deal status
    /// @dev 0=NotFound, 1=Active, 2=Success, 3=Failed, 4=Refunding, 5=Cancelled
    function status(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.partyA == address(0)) return 0; // NotFound

        State s = State(d.state);

        if (s == State.Completed) return 2; // Success
        if (s == State.Violated) return 3;  // Failed
        if (s == State.Settling) return 4;  // Refunding
        if (s == State.Cancelled) return 5; // Cancelled

        return 1; // Active (Created, Accepted, ClaimedDone)
    }

    /// @notice Business-specific deal status code
    function dealStatus(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];

        // Identify role
        bool isA = (msg.sender == d.partyA);
        bool isB = (msg.sender == d.partyB);
        bool isV = (msg.sender == d.verifier);
        if (!isA && !isB && !isV) return 12;

        State s = State(d.state);

        if (s == State.Created) {
            if (_isTimedOut(dealIndex)) {
                if (isA) return 0; // A can cancelDeal
                return 12;
            }
            if (isA) return 0;
            if (isB) return 1;
            return 11; // verifier
        }

        if (s == State.Accepted) {
            if (isA) return 2;
            if (isB) return 3;
            return 11; // verifier
        }

        if (s == State.ClaimedDone) {
            if (d.verificationRequested) {
                // Check if verifier timed out
                if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) {
                    if (isA || isB) return 13; // verifier timed out
                    return 11;
                }
                if (isV) return 7;
                return 6; // A or B waiting
            }
            if (isA) return 4;
            if (isB) return 5;
            return 11; // verifier
        }

        if (s == State.Settling) {
            if (!isA && !isB) return 12; // verifier/others not involved
            if (_isTimedOut(dealIndex)) return 16;
            Settlement storage stl = settlements[dealIndex];
            if (stl.proposer != address(0) && stl.proposer != msg.sender) return 15;
            return 14;
        }

        if (s == State.Completed) {
            return 8;
        }

        if (s == State.Cancelled) {
            return 17;
        }

        // Violated
        if (msg.sender == d.violator) return 9;
        if (isA || isB) return 10;
        return 8; // verifier sees terminated
    }

    /// @notice Whether a deal with the given index exists
    function dealExists(uint256 dealIndex) external view override returns (bool) {
        return deals[dealIndex].partyA != address(0);
    }
}
