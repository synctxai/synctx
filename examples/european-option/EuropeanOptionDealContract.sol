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

/// @title EuropeanOptionDealContract - 欧式期权 V1 核心交易合约
/// @notice V1 聚焦 pairwise explicit-consent 交易流，不在同一合约中实现公开 series/自动做市层。
/// @dev 核心流程：
///      1. Holder 创建 deal 并锁 premium
///      2. Writer 接受 deal 并锁 collateral
///      3. 到期后任一参与方可请求价格验证
///      4. Verifier 提交 settlement price，合约按 option type 自动结算
///      5. 若验证失败/不确定，则进入 Settling，由双方协商；超时则 unwind
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
    error InsufficientAllowance();
    error InsufficientBalance();
    error Reentrancy();

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

    uint256 private _lock;

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

    modifier nonReentrant() {
        if (_lock == 1) revert Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    modifier onlySlot0(uint256 verificationIndex) {
        if (verificationIndex != 0) revert InvalidVerificationIndex();
        _;
    }

    constructor(address requiredSpec) {
        _setInitializer();
        if (requiredSpec == address(0)) revert InvalidSpecAddress();
        REQUIRED_SPEC = requiredSpec;
    }

    function createDeal(CreateDealParams calldata p) external nonReentrant returns (uint256 dealIndex) {
        if (feeToken == address(0)) revert FeeTokenNotSet();
        if (p.writer == address(0) || p.writer == msg.sender || p.verifier == address(0) || p.underlying == address(0)) {
            revert InvalidParams();
        }
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

        _emitStateChanged(dealIndex, WAITING_ACCEPT);
    }

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
        _emitStateChanged(dealIndex, ACTIVE);
    }

    function cancelDeal(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.holder) revert NotHolder();
        if (d.status != WAITING_ACCEPT) revert InvalidStatus();
        if (!_isAcceptTimedOut(d)) revert NotTimedOut();

        uint256 premium = d.premium;
        d.premium = 0;
        d.status = CANCELLED;

        _emitPhaseChanged(dealIndex, 5);
        _emitStateChanged(dealIndex, CANCELLED);

        if (premium > 0) {
            if (!IERC20(feeToken).transfer(d.holder, premium)) revert TransferFailed();
        }
    }

    function requestVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        override
        onlySlot0(verificationIndex)
        nonReentrant
    {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.holder && msg.sender != d.writer) revert NotParty();
        if (d.status != ACTIVE) revert InvalidStatus();
        if (block.timestamp < uint256(d.expiry)) revert InvalidStatus();

        uint256 fee = d.verifierFee;
        if (IERC20(feeToken).allowance(msg.sender, address(this)) < fee) revert InsufficientAllowance();
        if (IERC20(feeToken).balanceOf(msg.sender) < fee) revert InsufficientBalance();

        d.status = VERIFYING;
        d.verificationTimestamp = uint48(block.timestamp);
        d.requesterIsHolder = (msg.sender == d.holder);

        emit VerificationRequested(dealIndex, verificationIndex, d.verifier);

        if (fee > 0) {
            if (!IERC20(feeToken).transferFrom(msg.sender, address(this), fee)) revert TransferFailed();
        }
    }

    function onVerificationResult(
        uint256 dealIndex,
        uint256 verificationIndex,
        int8 result,
        string calldata /* reason */
    ) external override onlySlot0(verificationIndex) nonReentrant {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.verifier) revert NotVerifier();
        if (d.status != VERIFYING) revert InvalidStatus();

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
        _emitStateChanged(dealIndex, SETTLING);

        if (verifierFee > 0) {
            if (!IERC20(feeToken).transfer(msg.sender, verifierFee)) revert TransferFailed();
        }
    }

    function resetVerification(uint256 dealIndex, uint256 verificationIndex)
        external
        onlySlot0(verificationIndex)
        nonReentrant
    {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.holder && msg.sender != d.writer) revert NotParty();
        if (d.status != VERIFYING) revert InvalidStatus();
        if (block.timestamp <= uint256(d.verificationTimestamp) + VERIFICATION_TIMEOUT) {
            revert VerificationNotTimedOut();
        }

        address requester = d.requesterIsHolder ? d.holder : d.writer;
        uint256 verifierFee = d.verifierFee;

        d.verificationTimestamp = 0;
        d.status = SETTLING;
        d.settlingTimestamp = uint48(block.timestamp);

        _emitStateChanged(dealIndex, SETTLING);

        if (verifierFee > 0) {
            if (!IERC20(feeToken).transfer(requester, verifierFee)) revert TransferFailed();
        }
    }

    function proposeSettlement(uint256 dealIndex, uint256 amountToHolder) external {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.holder && msg.sender != d.writer) revert NotParty();
        if (d.status != SETTLING) revert InvalidStatus();
        if (_isSettlingTimedOut(d)) revert AlreadyTimedOut();
        if (amountToHolder > d.reservedCollateral) revert InvalidSettlement();

        settlements[dealIndex] = SettlementProposal({
            proposer: msg.sender,
            amountToHolder: amountToHolder
        });
    }

    function confirmSettlement(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        SettlementProposal storage stl = settlements[dealIndex];
        if (msg.sender != d.holder && msg.sender != d.writer) revert NotParty();
        if (d.status != SETTLING) revert InvalidStatus();
        if (stl.proposer == address(0)) revert InvalidSettlement();
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

    function triggerSettlementTimeout(uint256 dealIndex) external nonReentrant {
        Deal storage d = deals[dealIndex];
        if (msg.sender != d.holder && msg.sender != d.writer) revert NotParty();
        if (d.status != SETTLING) revert InvalidStatus();
        if (!_isSettlingTimedOut(d)) revert SettlementNotTimedOut();

        uint256 premium = d.premium;
        uint256 collateral = d.reservedCollateral;
        address collateralToken = _collateralAsset(d);

        d.premium = 0;
        d.reservedCollateral = 0;
        d.status = UNWOUND;
        delete settlements[dealIndex];

        _emitStateChanged(dealIndex, UNWOUND);
        _emitPhaseChanged(dealIndex, 4);

        if (premium > 0) {
            if (!IERC20(feeToken).transfer(d.holder, premium)) revert TransferFailed();
        }
        if (collateral > 0) {
            if (!IERC20(collateralToken).transfer(d.writer, collateral)) revert TransferFailed();
        }
    }

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
                holderPayout = _mulDivUp(d.strike - settlementPrice, d.quantity, UNIT_SCALE);
                if (holderPayout > d.reservedCollateral) holderPayout = d.reservedCollateral;
            }
        } else {
            if (settlementPrice > d.strike) {
                holderPayout = _mulDivUp(settlementPrice - d.strike, d.quantity, settlementPrice);
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

        _emitStateChanged(dealIndex, COMPLETED);
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
            "Core European option deal. Pairwise explicit-consent flow with settlement-price verifier. "
            "PUT pays out in quote token; CALL pays out in underlying-equivalent units.";
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
        uint256 amountToWriter
    ) {
        SettlementProposal storage stl = settlements[dealIndex];
        if (stl.proposer == address(0)) return (address(0), 0, 0);
        uint256 total = deals[dealIndex].reservedCollateral;
        return (stl.proposer, stl.amountToHolder, total - stl.amountToHolder);
    }

    function instruction() external pure override returns (string memory) {
        return
            "# European Option Deal V1\n\n"
            "Core pairwise European option flow. Holder creates the deal and locks premium. Writer explicitly accepts and locks collateral. "
            "At expiry, either party may request settlement-price verification. "
            "PUT pays in quote token (`feeToken()`); CALL pays in underlying-equivalent units.\n\n"
            "## Parameters\n\n"
            "- `quantity`: underlying amount with 18 decimals\n"
            "- `strike`: quoteToken raw amount per 1 underlying\n"
            "- `premium`: quoteToken raw amount\n"
            "- `expiry`: Unix timestamp\n"
            "- `settlementWindow`: seconds after expiry used by the price verifier\n\n"
            "## V1 Constraints\n\n"
            "- underlying token must use 18 decimals\n"
            "- single verification slot only\n"
            "- no protocol fee in V1\n"
            "- no public series/orderbook layer in this contract; this is the core deal primitive\n\n"
            "## Flow\n\n"
            "1. Holder obtains verifier signature for (underlying, quoteToken, expiry, settlementWindow, fee)\n"
            "2. Holder approves premium and calls `createDeal`\n"
            "3. Writer approves collateral and calls `accept`\n"
            "4. After expiry, either party calls `requestVerification(dealIndex, 0)` and prepays verifier fee\n"
            "5. SettlementPriceVerifier signer reports a settlement price or inconclusive result\n"
            "6. Success: auto-settle. Inconclusive/failed/timeout: enter `Settling` for manual split, then timeout-unwind if still unresolved.\n";
    }
}
