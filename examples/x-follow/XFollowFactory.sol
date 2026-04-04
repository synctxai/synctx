// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DealBase.sol";
import "./IVerifier.sol";
import "./IERC20.sol";
import "./Initializable.sol";
import "./MetaTxMixin.sol";
import "./BindingAttestation.sol";
import "./Clones.sol";
import "./XFollowCampaign.sol";


/// @title XFollowFactory - X Paid Follow Campaign Factory Contract
/// @notice Developer deploys this contract. A creates XFollowCampaign clones via createDeal().
///         Each clone is an independent campaign with parameters locked at creation.
/// @dev Factory's dealIndex counts campaigns.
///      Sub-contract's dealIndex counts claims.
contract XFollowFactory is DealBase, Initializable, MetaTxMixin("XFollowFactory", "1") {

    // ===================== Errors =====================

    error InvalidParams();
    error TransferFailed();
    error VerifierNotContract();
    error InvalidVerifierSignature();
    error SignatureExpired();
    error InsufficientBudget();
    error FeeTokenNotSet();

    // ===================== Constants =====================

    uint96 public constant MIN_PROTOCOL_FEE = 10_000;

    // ===================== Immutable Config =====================

    /// @notice XFollowCampaign implementation contract address (clone source)
    address public immutable IMPLEMENTATION;

    /// @notice Protocol fee collector contract
    address public immutable FEE_COLLECTOR;

    /// @notice Per-claim protocol fee
    uint96 public immutable PROTOCOL_FEE;

    /// @notice Allowed VerifierSpec address
    address public immutable REQUIRED_SPEC;

    /// @notice Binding Attestation verification contract
    BindingAttestation public immutable BINDING_ATTESTATION;

    // ===================== Reentrancy Guard =====================

    uint256 private _lock = 1;

    modifier nonReentrant() {
        if (_lock == 2) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    error Reentrancy();

    // ===================== Campaign Tracking =====================

    /// @notice Factory dealIndex → campaign address
    mapping(uint256 => address) public campaigns;

    // ===================== BySig TYPEHASH Constants =====================

    bytes32 private constant _CREATE_DEAL_TYPEHASH = keccak256(
        "CreateDealBySig(uint96 grossAmount,address verifier,uint96 verifierFee,"
        "uint96 rewardPerFollow,uint256 sigDeadline,bytes32 sigHash,"
        "uint64 target_user_id,uint48 campaignDeadline,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    // ===================== Constructor =====================

    constructor(
        address implementation_,
        address feeCollector_,
        uint96  protocolFee_,
        address requiredSpec_,
        address bindingAttestation_
    ) {
        _setInitializer(); // for Initializable.setFeeToken()

        if (implementation_ == address(0) || implementation_.code.length == 0) revert InvalidParams();
        if (feeCollector_ == address(0) || feeCollector_.code.length == 0) revert InvalidParams();
        if (protocolFee_ < MIN_PROTOCOL_FEE) revert InvalidParams();
        if (requiredSpec_ == address(0) || requiredSpec_.code.length == 0) revert InvalidParams();
        if (bindingAttestation_ == address(0) || bindingAttestation_.code.length == 0) revert InvalidParams();

        IMPLEMENTATION = implementation_;
        FEE_COLLECTOR = feeCollector_;
        PROTOCOL_FEE = protocolFee_;
        REQUIRED_SPEC = requiredSpec_;
        BINDING_ATTESTATION = BindingAttestation(bindingAttestation_);
    }

    // ===================== Campaign Creation =====================

    /// @notice A creates a new XFollowCampaign (via EIP-1167 clone)
    /// @param grossAmount Total USDC budget deposited by A
    /// @param verifier_ Verifier contract address
    /// @param verifierFee_ Per-claim Verifier fee
    /// @param rewardPerFollow_ Reward per successful follow claim
    /// @param sigDeadline Verifier signature deadline
    /// @param sig Verifier's EIP-712 signature
    /// @param target_user_id_ Target Twitter user_id
    /// @param deadline_ Campaign end time
    /// @return campaign The newly created XFollowCampaign address
    function createDeal(
        uint96  grossAmount,
        address verifier_,
        uint96  verifierFee_,
        uint96  rewardPerFollow_,
        uint256 sigDeadline,
        bytes calldata sig,
        uint64  target_user_id_,
        uint48  deadline_
    ) external nonReentrant returns (address campaign) {
        return _createDealCore(msg.sender, grossAmount, verifier_, verifierFee_, rewardPerFollow_, sigDeadline, sig, target_user_id_, deadline_);
    }

    /// @notice A creates a new XFollowCampaign (gasless BySig version)
    function createDealBySig(
        uint96  grossAmount,
        address verifier_,
        uint96  verifierFee_,
        uint96  rewardPerFollow_,
        uint256 sigDeadline,
        bytes calldata sig,
        uint64  target_user_id_,
        uint48  deadline_,
        PermitData calldata permit,
        MetaTxProof calldata proof
    ) external nonReentrant returns (address campaign) {
        bytes32 structHash = keccak256(abi.encode(
            _CREATE_DEAL_TYPEHASH,
            grossAmount, verifier_, verifierFee_,
            rewardPerFollow_, sigDeadline, keccak256(sig),
            target_user_id_, deadline_,
            proof.signer, proof.relayer, proof.nonce, proof.deadline
        ));
        _verifyMetaTx(structHash, proof);
        _executePermit(permit, proof.signer);
        return _createDealCore(proof.signer, grossAmount, verifier_, verifierFee_, rewardPerFollow_, sigDeadline, sig, target_user_id_, deadline_);
    }

    function _createDealCore(
        address sender,
        uint96  grossAmount,
        address verifier_,
        uint96  verifierFee_,
        uint96  rewardPerFollow_,
        uint256 sigDeadline,
        bytes calldata sig,
        uint64  target_user_id_,
        uint48  deadline_
    ) internal returns (address campaign) {
        if (feeToken == address(0)) revert FeeTokenNotSet();

        // Basic validation (detailed validation done by campaign.initialize)
        if (grossAmount < rewardPerFollow_ + verifierFee_ + PROTOCOL_FEE) revert InsufficientBudget();

        // 1. Clone
        campaign = Clones.clone(IMPLEMENTATION);

        // 2. Transfer USDC from A to campaign
        if (!IERC20(feeToken).transferFrom(sender, campaign, grossAmount)) revert TransferFailed();

        // 3. Initialize clone
        XFollowCampaign(campaign).initialize(
            feeToken,
            FEE_COLLECTOR,
            PROTOCOL_FEE,
            REQUIRED_SPEC,
            address(BINDING_ATTESTATION),
            sender,             // partyA
            verifier_,
            rewardPerFollow_,
            verifierFee_,
            deadline_,
            grossAmount,
            target_user_id_,
            sigDeadline,
            sig
        );

        // 4. Record in factory (dealIndex = campaign sequence number)
        address[] memory traders = new address[](1);
        traders[0] = sender;
        address[] memory verifiers = new address[](1);
        verifiers[0] = verifier_;
        uint256 campaignIndex = _recordStart(traders, verifiers);
        campaigns[campaignIndex] = campaign;

        // 5. Platform auto-discovery
        emit SubContractCreated(campaign);
    }

    // ===================== IDeal Implementation (Factory Level) =====================

    function name() external pure override returns (string memory) {
        return "X(Twitter) Follow Campaign Builder";
    }

    function description() external pure override returns (string memory) {
        return "Create X(Twitter) Follow Campaigns. Pay followers fixed USDC rewards for following your Twitter account.";
    }

    function tags() external pure override returns (string[] memory) {
        string[] memory t = new string[](5);
        t[0] = "x";
        t[1] = "follow";
        t[2] = "twitter";
        t[3] = "kol";
        t[4] = "campaign";
        return t;
    }

    function version() external pure override returns (string memory) {
        return "5.0";
    }

    function protocolFeePolicy() external pure override returns (string memory) {
        return
            "No upfront fee at campaign creation. "
            "Per-claim protocol fee deducted from campaign budget on successful claims only. "
            "Failed claims: only verifierFee deducted. Inconclusive: full refund.";
    }

    function requiredSpecs() external view override returns (address[] memory) {
        address[] memory specs = new address[](1);
        specs[0] = REQUIRED_SPEC;
        return specs;
    }

    /// @notice Factory does not provide per-claim verification params; query the specific campaign sub-contract
    function verificationParams(uint256, uint256)
        external pure override
        returns (address, uint256, uint256, bytes memory, bytes memory)
    {
        revert("query campaign contract directly");
    }

    /// @notice Factory does not accept verification requests
    function requestVerification(uint256, uint256) external pure override {
        revert("query campaign contract directly");
    }

    /// @notice Factory-level phase: 1=Created (campaign deployed)
    function phase(uint256 dealIndex) external view override returns (uint8) {
        if (campaigns[dealIndex] == address(0)) return 0; // NotFound
        return 1; // Created
    }

    /// @notice Factory-level dealStatus: whether the campaign address exists
    function dealStatus(uint256 dealIndex) external view override returns (uint8) {
        if (campaigns[dealIndex] == address(0)) return 255; // NOT_FOUND
        return 1; // CREATED
    }

    function dealExists(uint256 dealIndex) external view override returns (bool) {
        return campaigns[dealIndex] != address(0);
    }

    function instruction() external view override returns (string memory) {
        return
            "# X(Twitter) Follow Campaign Builder\n\n"
            "Create paid follow campaigns on X(Twitter). Set a budget, define rewards, and followers earn USDC for following your account.\n\n"
            "## createDeal Parameters\n\n"
            "| Parameter | Type | Description |\n"
            "|------|------|------|\n"
            "| grossAmount | uint96 | Total campaign budget (USDC raw value). Covers all rewards + verifier fees + protocol fees |\n"
            "| verifier | address | Verifier contract address |\n"
            "| verifierFee | uint96 | Per-claim verification fee (USDC raw value) |\n"
            "| rewardPerFollow | uint96 | Reward per successful follow (USDC raw value) |\n"
            "| sigDeadline | uint256 | Verifier signature validity (Unix seconds), must >= campaign deadline + 30min |\n"
            "| sig | bytes | Verifier EIP-712 signature |\n"
            "| target_user_id | uint64 | Target X(Twitter) immutable user_id to be followed |\n"
            "| deadline | uint48 | Campaign end time (Unix seconds) |\n\n"
            "**Prerequisites**:\n"
            "1. Obtain verifier signature via `request_sign` (sig + fee)\n"
            "2. USDC `approve(builder address, grossAmount)` -- the full budget is transferred to the campaign on creation\n"
            "3. Query `PROTOCOL_FEE()` to get per-claim protocol fee, then: grossAmount = slots * (rewardPerFollow + verifierFee + PROTOCOL_FEE)\n\n"
            "## After Creation\n\n"
            "- `createDeal` returns the deployed campaign contract address. Also emitted in `SubContractCreated` event.\n"
            "- Query `campaigns(dealIndex)` on the builder to retrieve the campaign address.\n"
            "- All follower interactions (claim, status queries) happen on the campaign contract, not the builder.\n"
            "- Read the campaign's `instruction()` for follower-facing operations and dealStatus guide.\n\n"
            "## Builder dealStatus\n\n"
            "| Code | Status | Meaning |\n"
            "|----|------|------|\n"
            "| 1 | Created | Campaign deployed and live |\n"
            "| 255 | NotFound | No campaign at this index |\n\n"
            "## Gasless Relay\n\n"
            "createDeal optionally supports gasless relay via `createDealBySig` (EIP-712 meta-transaction). "
            "The user signs, a relayer submits on-chain and pays gas.\n";
    }
}
