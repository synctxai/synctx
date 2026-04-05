// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../contracts/DealBase.sol";
import "../../contracts/IVerifier.sol";
import "../../contracts/IERC20.sol";
import "../../contracts/Initializable.sol";
import "../european-option-verifier-spec/SettlementPriceVerifierSpec.sol";

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}

interface ISettlementPriceVerifierLike {
    function settlementPriceOf(address dealContract, uint256 dealIndex, uint256 verificationIndex)
        external
        view
        returns (uint256);
}

/// @title EuropeanOptionDealContract - European Option V1 Core Deal Contract
/// @notice V1 focuses on pairwise explicit-consent deal flow; no public series/AMM layer in the same contract.
/// @dev Core flow:
///      1. Holder creates deal and locks premium
///      2. Writer accepts deal and locks collateral
///      3. After expiry, either party can request price verification
///      4. Verifier submits settlement price, contract auto-settles based on option type
///      5. If verification fails/inconclusive, enters Settling for manual negotiation; unwind on timeout
contract EuropeanOptionDealContract is DealBase, Initializable {

    error FeeTokenNotSet();
    error InvalidParams();
    error InvalidOptionType();
    error UnderlyingMustUse18Decimals();
    error NotHolder();
    error NotWriter();
    error NotVerifier();
    error NotParty();
    error InvalidStatus();
    error NotTimedOut();
    error AlreadyTimedOut();
    error InvalidVerificationIndex();
    error InvalidSpecAddress();
    error InvalidVerifierSignature();
    error SignatureExpired();
    error TransferFailed();
    error NoSettlementPrice();
    error ProposerCannotConfirm();
    error InvalidSettlement();
    error VerificationNotTimedOut();
    error SettlementNotTimedOut();
    error SettlementTimedOut();
    error VerifierTimedOut();
    error Reentrancy();
    error VersionMismatch();
    error NotAdmin();
    error ContractNotOpen();
    error ContractAlreadyOpen();

    uint8 public constant OPTION_PUT = 0;
    uint8 public constant OPTION_CALL = 1;

    uint8 private constant WAITING_ACCEPT = 0;
    uint8 private constant ACTIVE = 1;
    uint8 private constant VERIFYING = 2;
    uint8 private constant SETTLING = 3;
    uint8 private constant COMPLETED = 4;
    uint8 private constant CANCELLED = 5;
    uint8 private constant UNWOUND = 6;
    uint8 private constant NOT_FOUND = 255;

    uint8 private constant ACCEPT_TIMED_OUT = 7;
    uint8 private constant EXPIRED = 8;
    uint8 private constant VERIFIER_TIMED_OUT = 9;
    uint8 private constant SETTLEMENT_PROPOSED = 10;
    uint8 private constant SETTLEMENT_TIMED_OUT = 11;

    uint256 public constant UNIT_SCALE = 1e18;
    uint256 public constant ACCEPT_TIMEOUT = 1 days;
    uint256 public constant VERIFICATION_TIMEOUT = 1 days;
    uint256 public constant SETTLING_TIMEOUT = 3 days;
    uint256 public constant MIN_EXPIRY_LEAD = 1 hours;

    address public immutable REQUIRED_SPEC;

    // ===================== Contract Lifecycle =====================

    uint8   private _serviceMode;      // MODE_TESTING → MODE_OPENING or MODE_CLOSED
    address private _admin;            // deployer, permanently cleared after goLive()

    uint256 private _lock = 1;

    struct Deal {
        address holder;
        address writer;
        address underlying;
        address verifier;
        uint48 createdAt;
        uint48 verificationTimestamp;
        uint48 settlingTimestamp;
        uint48 expiry;
        uint32 settlementWindow;
        uint8 optionType;
        uint8 status;
        bool requesterIsHolder;
        uint96 verifierFee;
        uint256 quantity;            // 18 decimals, e.g. 1 ETH = 1e18
        uint256 strike;              // quoteToken raw amount per 1 underlying
        uint256 premium;             // quoteToken raw amount
        uint256 reservedCollateral;  // PUT=USDC, CALL=underlying
        uint256 signatureDeadline;
        bytes verifierSignature;
    }

    struct SettlementProposal {
        address proposer;
        uint256 amountToHolder; // denominated in collateral asset
        uint256 version;        // Proposal version, incremented on each proposal
    }

    struct CreateDealParams {
        address writer;
        address underlying;
        uint8 optionType;
        uint256 quantity;
        uint256 strike;
        uint256 premium;
        uint48 expiry;
        uint32 settlementWindow;
        address verifier;
        uint96 verifierFee;
        uint256 verifierDeadline;
        bytes verifierSig;
    }

    mapping(uint256 => Deal) internal deals;
    mapping(uint256 => SettlementProposal) internal settlements;

    // ===================== Modifiers =====================

    modifier nonReentrant() {
        if (_lock == 2) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlySlot0(uint256 verificationIndex) {
        if (verificationIndex != 0) revert InvalidVerificationIndex();
        _;
    }

    constructor(address requiredSpec) {
        _setInitializer();
        if (requiredSpec == address(0) || requiredSpec.code.length == 0) revert InvalidSpecAddress();
        REQUIRED_SPEC = requiredSpec;
        _admin = msg.sender;
        // _serviceMode defaults to 0 = MODE_TESTING
    }

    // ===================== Contract Lifecycle Management =====================

    modifier onlyAdmin() {
        if (msg.sender != _admin) revert NotAdmin();
        _;
    }

    /// @notice TESTING → OPENING: freeze params, permanently destroy admin privileges, irreversible
    function goLive() external onlyAdmin {
        if (_serviceMode != MODE_TESTING) revert ContractAlreadyOpen();
        _serviceMode = MODE_OPENING;
        _admin = address(0);
        _emitServiceModeChanged(MODE_OPENING);
    }

    /// @notice TESTING → CLOSED: testing failed, discard contract, irreversible
    function closeDuringTesting() external onlyAdmin {
        if (_serviceMode != MODE_TESTING) revert ContractAlreadyOpen();
        _serviceMode = MODE_CLOSED;
        _admin = address(0);
        _emitServiceModeChanged(MODE_CLOSED);
    }

    function serviceMode() external view override returns (uint8) {
        return _serviceMode;
    }

    // ===================== createDeal =====================

    function createDeal(CreateDealParams calldata p) external nonReentrant returns (uint256 dealIndex) {
        if (_serviceMode == MODE_CLOSED) revert ContractNotOpen();
        if (feeToken == address(0)) revert FeeTokenNotSet();
        if (p.writer == address(0) || p.writer == msg.sender || p.verifier == address(0) || p.underlying == address(0)) {
            revert InvalidParams();
        }
        if (p.underlying == feeToken) revert InvalidParams();
        if (p.optionType != OPTION_PUT && p.optionType != OPTION_CALL) revert InvalidOptionType();
        if (p.quantity == 0 || p.strike == 0 || p.premium == 0 || p.settlementWindow == 0) revert InvalidParams();
        if (p.expiry <= block.timestamp + MIN_EXPIRY_LEAD) revert InvalidParams();
        if (p.underlying.code.length == 0 || p.verifier.code.length == 0) revert InvalidParams();
        if (IERC20MetadataLike(p.underlying).decimals() != 18) revert UnderlyingMustUse18Decimals();
        if (p.verifierDeadline < block.timestamp) revert SignatureExpired();
        if (p.verifierSig.length == 0) revert InvalidVerifierSignature();

        _verifyVerifierSignature(
            p.verifier,
            p.underlying,
            feeToken,
            p.expiry,
            p.settlementWindow,
            p.verifierFee,
            p.verifierDeadline,
            p.verifierSig
        );

        if (!IERC20(feeToken).transferFrom(msg.sender, address(this), p.premium)) revert TransferFailed();

        {
            address[] memory traders = new address[](2);
            traders[0] = msg.sender;
            traders[1] = p.writer;
            address[] memory verifiers = new address[](1);
            verifiers[0] = p.verifier;
            dealIndex = _recordStart(traders, verifiers);
        }

        Deal storage d = deals[dealIndex];
        d.holder = msg.sender;
        d.writer = p.writer;
        d.underlying = p.underlying;
        d.verifier = p.verifier;
        d.createdAt = uint48(block.timestamp);
        d.expiry = p.expiry;
        d.settlementWindow = p.settlementWindow;
        d.optionType = p.optionType;
        d.status = WAITING_ACCEPT;
        d.verifierFee = p.verifierFee;
        d.quantity = p.quantity;
        d.strike = p.strike;
        d.premium = p.premium;
        d.signatureDeadline = p.verifierDeadline;
        d.verifierSignature = p.verifierSig;

        _emitStatusChanged(dealIndex, WAITING_ACCEPT);
    }

    // ===================== accept =====================

    function accept(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.writer) revert NotWriter();
        if (d.status != WAITING_ACCEPT) revert InvalidStatus();
        if (_isAcceptTimedOut(d)) revert AlreadyTimedOut();

        uint256 collateral = _requiredCollateral(d.optionType, d.quantity, d.strike);
        address collateralToken = _collateralAsset(d);

        if (!IERC20(collateralToken).transferFrom(msg.sender, address(this), collateral)) revert TransferFailed();

        d.reservedCollateral = collateral;
        d.status = ACTIVE;

        _emitPhaseChanged(dealIndex, 2);
        _emitStatusChanged(dealIndex, ACTIVE);
    }

    // ===================== cancelDeal =====================

    function cancelDeal(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.holder) revert NotHolder();
        if (d.status != WAITING_ACCEPT) revert InvalidStatus();
        if (!_isAcceptTimedOut(d)) revert NotTimedOut();

        uint256 premium = d.premium;
        d.premium = 0;
        d.status = CANCELLED;

        _emitPhaseChanged(dealIndex, 5);
        _emitStatusChanged(dealIndex, CANCELLED);

        if (premium > 0) {
            if (!IERC20(feeToken).transfer(d.holder, premium)) revert TransferFailed();
        }
    }

    // ===================== requestVerification =====================

    function requestVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        override
        nonReentrant
    {
        if (verificationIndex != 0) revert InvalidVerificationIndex();

        Deal storage d = deals[dealIndex];
        if (msg.sender != d.holder && msg.sender != d.writer) revert NotParty();
        if (d.status != ACTIVE) revert InvalidStatus();
        if (block.timestamp < uint256(d.expiry)) revert InvalidStatus();

        uint256 fee = d.verifierFee;

        d.status = VERIFYING;
        d.verificationTimestamp = uint48(block.timestamp);
        d.requesterIsHolder = (msg.sender == d.holder);

        emit VerificationRequested(dealIndex, verificationIndex, d.verifier);

        if (fee > 0) {
            if (!IERC20(feeToken).transferFrom(msg.sender, address(this), fee)) revert TransferFailed();
        }
    }

    // ===================== onVerificationResult =====================

    function onVerificationResult(
        uint256 dealIndex,
        uint256 verificationIndex,
        int8 result,
        string calldata /* reason */
    ) external override onlySlot0(verificationIndex) nonReentrant {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.verifier) revert NotVerifier();
        if (d.status != VERIFYING) revert InvalidStatus();
        if (block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) revert VerifierTimedOut();

        d.verificationTimestamp = 0;

        uint256 verifierFee = d.verifierFee;

        if (result > 0) {
            uint256 settlementPrice =
                ISettlementPriceVerifierLike(msg.sender).settlementPriceOf(address(this), dealIndex, verificationIndex);
            if (settlementPrice == 0) revert NoSettlementPrice();

            _settleWithPrice(dealIndex, d, settlementPrice, verifierFee, msg.sender);
            return;
        }

        d.status = SETTLING;
        d.settlingTimestamp = uint48(block.timestamp);

        emit VerificationReceived(dealIndex, verificationIndex, msg.sender, result);
        _emitStatusChanged(dealIndex, SETTLING);

        if (verifierFee > 0) {
            if (result < 0) {
                // failure — verifier completed work, pay fee
                if (!IERC20(feeToken).transfer(msg.sender, verifierFee)) revert TransferFailed();
            } else {
                // inconclusive — no settlement price delivered, refund to requester
                address requester = d.requesterIsHolder ? d.holder : d.writer;
                if (!IERC20(feeToken).transfer(requester, verifierFee)) revert TransferFailed();
            }
        }
    }

    // ===================== resetVerification =====================

    function resetVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        onlySlot0(verificationIndex)
        nonReentrant
    {
        Deal storage d = deals[dealIndex];
        address sender = msg.sender;
        if (sender != d.holder && sender != d.writer) revert NotParty();
        if (d.status != VERIFYING) revert InvalidStatus();
        if (block.timestamp <= uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) {
            revert VerificationNotTimedOut();
        }

        address requester = d.requesterIsHolder ? d.holder : d.writer;
        uint256 verifierFee = d.verifierFee;

        d.verificationTimestamp = 0;
        d.status = SETTLING;
        d.settlingTimestamp = uint48(block.timestamp);

        _emitStatusChanged(dealIndex, SETTLING);

        if (verifierFee > 0) {
            if (!IERC20(feeToken).transfer(requester, verifierFee)) revert TransferFailed();
        }
    }

    // ===================== proposeSettlement =====================

    function proposeSettlement(uint256 dealIndex, uint256 amountToHolder) external nonReentrant {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.holder && msg.sender != d.writer) revert NotParty();
        if (d.status != SETTLING) revert InvalidStatus();
        if (_isSettlingTimedOut(d)) revert AlreadyTimedOut();
        if (amountToHolder > d.reservedCollateral) revert InvalidSettlement();

        SettlementProposal storage stl = settlements[dealIndex];
        stl.proposer = msg.sender;
        stl.amountToHolder = amountToHolder;
        stl.version += 1;

        emit SettlementProposed(dealIndex, msg.sender, amountToHolder, stl.version);
    }

    // ===================== confirmSettlement =====================

    function confirmSettlement(uint256 dealIndex, uint256 expectedVersion) external nonReentrant {
        Deal storage d = deals[dealIndex];
        SettlementProposal storage stl = settlements[dealIndex];
        if (msg.sender != d.holder && msg.sender != d.writer) revert NotParty();
        if (d.status != SETTLING) revert InvalidStatus();
        if (_isSettlingTimedOut(d)) revert SettlementTimedOut();
        if (stl.proposer == address(0)) revert InvalidSettlement();
        if (stl.version != expectedVersion) revert VersionMismatch();
        if (msg.sender == stl.proposer) revert ProposerCannotConfirm();

        _executeSettlement(
            dealIndex,
            d,
            stl.amountToHolder,
            d.reservedCollateral - stl.amountToHolder,
            d.premium
        );
        delete settlements[dealIndex];
    }

    // ===================== triggerSettlementTimeout =====================

    function triggerSettlementTimeout(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        address sender = msg.sender;
        if (sender != d.holder && sender != d.writer) revert NotParty();
        if (d.status != SETTLING) revert InvalidStatus();
        if (!_isSettlingTimedOut(d)) revert SettlementNotTimedOut();

        uint256 premium = d.premium;
        uint256 collateral = d.reservedCollateral;
        address collateralToken = _collateralAsset(d);

        d.premium = 0;
        d.reservedCollateral = 0;
        d.status = UNWOUND;
        delete settlements[dealIndex];

        _emitStatusChanged(dealIndex, UNWOUND);
        _emitPhaseChanged(dealIndex, 4);

        if (premium > 0) {
            if (!IERC20(feeToken).transfer(d.holder, premium)) revert TransferFailed();
        }
        if (collateral > 0) {
            if (!IERC20(collateralToken).transfer(d.writer, collateral)) revert TransferFailed();
        }
    }

    // ===================== Internal Settlement Logic =====================

    function _settleWithPrice(
        uint256 dealIndex,
        Deal storage d,
        uint256 settlementPrice,
        uint256 verifierFee,
        address verifierAddr
    ) internal {
        emit VerificationReceived(dealIndex, 0, verifierAddr, 1);

        uint256 holderPayout;
        if (d.optionType == OPTION_PUT) {
            if (settlementPrice < d.strike) {
                holderPayout = (d.strike - settlementPrice) * d.quantity / UNIT_SCALE;
                if (holderPayout > d.reservedCollateral) holderPayout = d.reservedCollateral;
            }
        } else {
            if (settlementPrice > d.strike) {
                holderPayout = (settlementPrice - d.strike) * d.quantity / settlementPrice;
                if (holderPayout > d.reservedCollateral) holderPayout = d.reservedCollateral;
            }
        }

        _executeSettlement(
            dealIndex,
            d,
            holderPayout,
            d.reservedCollateral - holderPayout,
            d.premium
        );

        if (verifierFee > 0) {
            if (!IERC20(feeToken).transfer(verifierAddr, verifierFee)) revert TransferFailed();
        }
    }

    function _executeSettlement(
        uint256 dealIndex,
        Deal storage d,
        uint256 collateralToHolder,
        uint256 collateralToWriter,
        uint256 premiumToWriter
    ) internal {
        address collateralToken = _collateralAsset(d);

        d.premium = 0;
        d.reservedCollateral = 0;
        d.status = COMPLETED;

        _emitStatusChanged(dealIndex, COMPLETED);
        _emitPhaseChanged(dealIndex, 3);

        if (collateralToHolder > 0) {
            if (!IERC20(collateralToken).transfer(d.holder, collateralToHolder)) revert TransferFailed();
        }
        if (collateralToWriter > 0) {
            if (!IERC20(collateralToken).transfer(d.writer, collateralToWriter)) revert TransferFailed();
        }
        if (premiumToWriter > 0) {
            if (!IERC20(feeToken).transfer(d.writer, premiumToWriter)) revert TransferFailed();
        }
    }

    function _verifyVerifierSignature(
        address verifier,
        address underlying,
        address quoteToken,
        uint256 expiry,
        uint256 settlementWindow,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) internal view {
        address verifierSpec = IVerifier(verifier).spec();
        if (verifierSpec != REQUIRED_SPEC) revert InvalidSpecAddress();
        address recovered = SettlementPriceVerifierSpec(verifierSpec).check(
            verifier,
            underlying,
            quoteToken,
            expiry,
            settlementWindow,
            fee,
            deadline,
            sig
        );
        if (recovered != IVerifier(verifier).signer()) revert InvalidVerifierSignature();
    }

    function _requiredCollateral(uint8 optionType, uint256 quantity, uint256 strike) internal pure returns (uint256) {
        if (optionType == OPTION_PUT) {
            return _mulDivUp(strike, quantity, UNIT_SCALE);
        }
        if (optionType == OPTION_CALL) {
            return quantity;
        }
        revert InvalidOptionType();
    }

    function _collateralAsset(Deal storage d) internal view returns (address) {
        return d.optionType == OPTION_PUT ? feeToken : d.underlying;
    }

    function _isAcceptTimedOut(Deal storage d) internal view returns (bool) {
        return block.timestamp > uint256(d.createdAt) + ACCEPT_TIMEOUT;
    }

    function _isSettlingTimedOut(Deal storage d) internal view returns (bool) {
        return block.timestamp > uint256(d.settlingTimestamp) + SETTLING_TIMEOUT;
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 denom) internal pure returns (uint256) {
        return (a * b + denom - 1) / denom;
    }

    // ===================== Queries =====================

    function name() external pure override returns (string memory) {
        return "European Option Deal";
    }

    function description() external pure override returns (string memory) {
        return
            "Pairwise European option deal. 2-party (holder + writer), USDC premium. "
            "PUT settles in quote token; CALL settles in underlying token.";
    }

    function tags() external pure override returns (string[] memory) {
        string[] memory t = new string[](2);
        t[0] = "options";
        t[1] = "european";
        return t;
    }

    function version() external pure override returns (string memory) {
        return "1.0";
    }

    function protocolFeePolicy() external pure override returns (string memory) {
        return
            "V1 core option deal charges no protocol fee. "
            "Holder locks premium on createDeal. Writer locks collateral on accept. "
            "Requester separately funds verifierFee when calling requestVerification.";
    }

    function requiredSpecs() external view override returns (address[] memory) {
        address[] memory specs = new address[](1);
        specs[0] = REQUIRED_SPEC;
        return specs;
    }

    function verificationParams(uint256 dealIndex, uint256 verificationIndex)
        external
        view
        override
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
        if (d.holder == address(0)) revert InvalidParams();

        specParams = abi.encode(d.underlying, feeToken, uint256(d.expiry), uint256(d.settlementWindow));
        return (d.verifier, uint256(d.verifierFee), d.signatureDeadline, d.verifierSignature, specParams);
    }

    function phase(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.holder == address(0)) return 0;

        uint8 s = d.status;
        if (s == WAITING_ACCEPT) return 1;
        if (s == COMPLETED) return 3;
        if (s == CANCELLED) return 5;
        if (s == UNWOUND) return 4;
        return 2;
    }

    function dealStatus(uint256 dealIndex) external view override returns (uint8) {
        Deal storage d = deals[dealIndex];
        if (d.holder == address(0)) return NOT_FOUND;

        uint8 s = d.status;
        if (s == WAITING_ACCEPT) {
            return _isAcceptTimedOut(d) ? ACCEPT_TIMED_OUT : WAITING_ACCEPT;
        }
        if (s == ACTIVE) {
            return block.timestamp >= uint256(d.expiry) ? EXPIRED : ACTIVE;
        }
        if (s == VERIFYING) {
            return block.timestamp > uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT
                ? VERIFIER_TIMED_OUT
                : VERIFYING;
        }
        if (s == SETTLING) {
            if (_isSettlingTimedOut(d)) return SETTLEMENT_TIMED_OUT;
            if (settlements[dealIndex].proposer != address(0)) return SETTLEMENT_PROPOSED;
            return SETTLING;
        }
        return s;
    }

    function dealExists(uint256 dealIndex) external view override returns (bool) {
        return deals[dealIndex].holder != address(0);
    }

    function collateralAsset(uint256 dealIndex) external view returns (address) {
        Deal storage d = deals[dealIndex];
        if (d.holder == address(0)) revert InvalidParams();
        return _collateralAsset(d);
    }

    function timeRemaining(uint256 dealIndex) external view returns (uint256) {
        Deal storage d = deals[dealIndex];
        uint256 deadline_;
        if (d.status == WAITING_ACCEPT) {
            deadline_ = uint256(d.createdAt) + ACCEPT_TIMEOUT;
        } else if (d.status == ACTIVE) {
            deadline_ = uint256(d.expiry);
        } else if (d.status == VERIFYING) {
            deadline_ = uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT;
        } else if (d.status == SETTLING) {
            deadline_ = uint256(d.settlingTimestamp) + SETTLING_TIMEOUT;
        } else {
            return 0;
        }
        if (block.timestamp >= deadline_) return 0;
        return deadline_ - block.timestamp;
    }

    function settlement(uint256 dealIndex) external view returns (
        address proposer,
        uint256 amountToHolder,
        uint256 amountToWriter,
        uint256 settlementVersion
    ) {
        SettlementProposal storage stl = settlements[dealIndex];
        if (stl.proposer == address(0)) return (address(0), 0, 0, 0);
        uint256 total = deals[dealIndex].reservedCollateral;
        return (stl.proposer, stl.amountToHolder, total - stl.amountToHolder, stl.version);
    }

    function instruction() external pure override returns (string memory) {
        return
            "# European Option Deal V1\n\n"
            "Pairwise European option flow. Holder creates the deal and locks premium. Writer explicitly accepts and locks collateral. "
            "At expiry, either party may request settlement-price verification. "
            "PUT settles in quote token (`feeToken()`); CALL settles in underlying token.\n\n"
            "## Parameters\n\n"
            "| Parameter | Type | Description |\n"
            "|------|------|------|\n"
            "| writer | address | Option writer (counterparty) address |\n"
            "| underlying | address | Underlying token address (must use 18 decimals) |\n"
            "| optionType | uint8 | 0 = PUT, 1 = CALL |\n"
            "| quantity | uint256 | Underlying amount with 18 decimals (e.g. 1 ETH = 1e18) |\n"
            "| strike | uint256 | Quote token raw amount per 1 underlying |\n"
            "| premium | uint256 | Quote token raw amount paid by Holder |\n"
            "| expiry | uint48 | Option expiry (Unix timestamp) |\n"
            "| settlementWindow | uint32 | Seconds after expiry for the price verifier to report |\n"
            "| verifier | address | Verifier contract address |\n"
            "| verifierFee | uint96 | Verification fee (quote token raw value) |\n"
            "| verifierDeadline | uint256 | Verifier signature validity (Unix seconds) |\n"
            "| verifierSig | bytes | Verifier EIP-712 signature |\n\n"
            "**Collateral**: PUT = `strike * quantity / 1e18` in quote token; CALL = `quantity` in underlying token.\n\n"
            "## V1 Constraints\n\n"
            "- Underlying token must use 18 decimals\n"
            "- Single verification slot only\n"
            "- No protocol fee in V1\n"
            "- No public series/orderbook layer; this is the core deal primitive\n\n"
            "## Flow\n\n"
            "1. Holder obtains verifier signature for (underlying, quoteToken, expiry, settlementWindow, fee)\n"
            "2. Holder approves premium in quote token and calls `createDeal`\n"
            "3. Writer approves collateral and calls `accept(dealIndex)`\n"
            "4. After expiry, either party calls `requestVerification(dealIndex, 0)` and prepays verifier fee\n"
            "5. **Must** notify the verifier to begin verification\n"
            "6. Verifier reports settlement price on-chain, triggering auto-settlement\n"
            "7. If verification fails/inconclusive/times out: enters Settling for manual negotiation; unwind on timeout\n\n"
            "## dealStatus Action Guide\n\n"
            "`dealStatus(dealIndex)` returns the current status. Use `timeRemaining(dealIndex)` to query remaining seconds.\n\n"
            "| Code | Status | Holder Action | Writer Action |\n"
            "|----|------|------|------|\n"
            "| 0 | WaitingAccept | Wait for Writer | `accept(dealIndex)` |\n"
            "| 7 | AcceptTimedOut | `cancelDeal(dealIndex)` to reclaim premium | -- |\n"
            "| 1 | Active | Wait for expiry | Wait for expiry |\n"
            "| 8 | Expired | `requestVerification(dealIndex, 0)` | `requestVerification(dealIndex, 0)` |\n"
            "| 2 | Verifying | Wait | Wait |\n"
            "| 9 | VerifierTimedOut | `resetVerification(dealIndex, 0)` | `resetVerification(dealIndex, 0)` |\n"
            "| 3 | Settling | `proposeSettlement(dealIndex, amountToHolder)` | `proposeSettlement(dealIndex, amountToHolder)` |\n"
            "| 10 | SettlementProposed | `confirmSettlement(dealIndex, expectedVersion)` or update proposal | `confirmSettlement(dealIndex, expectedVersion)` or update proposal |\n"
            "| 11 | SettlementTimedOut | `triggerSettlementTimeout(dealIndex)` | `triggerSettlementTimeout(dealIndex)` |\n"
            "| 4 | Completed | -- | -- |\n"
            "| 5 | Cancelled | -- | -- |\n"
            "| 6 | Unwound | -- (premium returned to Holder, collateral to Writer) | -- |\n"
            "| 255 | NotFound | Deal does not exist | Deal does not exist |\n\n"
            "> **Timeouts**: Accept = 1 day, Verification = 1 day, Settlement = 3 days.\n\n"
            "> **Settlement semantics**: `proposeSettlement(dealIndex, amountToHolder)` where amountToHolder is denominated in the collateral asset. Remainder goes to Writer. Call `settlement(dealIndex)` to query the current proposal and its version. `confirmSettlement(dealIndex, expectedVersion)` accepts the counterparty's proposal; pass the version from `settlement()` as expectedVersion.\n";
    }
}
