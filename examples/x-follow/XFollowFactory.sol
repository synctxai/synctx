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


/// @title XFollowFactory - X 付费关注 Campaign 工厂合约
/// @notice Developer 部署此合约。A 通过 createDeal() 创建 XFollowCampaign clone。
///         每个 clone 是独立的 campaign，参数创建时锁定。
/// @dev Factory 的 dealIndex 计数 campaign 数量。
///      子合约的 dealIndex 计数 claim 数量。
contract XFollowFactory is DealBase, Initializable, MetaTxMixin("XFollowFactory", "1") {

    // ===================== 错误 =====================

    error InvalidParams();
    error TransferFailed();
    error VerifierNotContract();
    error InvalidVerifierSignature();
    error SignatureExpired();
    error InsufficientBudget();
    error FeeTokenNotSet();

    // ===================== 常量 =====================

    uint96 public constant MIN_PROTOCOL_FEE = 10_000;

    // ===================== 不可变配置 =====================

    /// @notice XFollowCampaign 实现合约地址（clone 的 implementation）
    address public immutable IMPLEMENTATION;

    /// @notice 协议费收集合约
    address public immutable FEE_COLLECTOR;

    /// @notice 每次 claim 的协议费
    uint96 public immutable PROTOCOL_FEE;

    /// @notice 允许的 VerifierSpec 地址
    address public immutable REQUIRED_SPEC;

    /// @notice Binding Attestation 认证合约
    BindingAttestation public immutable BINDING_ATTESTATION;

    // ===================== 重入保护 =====================

    uint256 private _lock = 1;

    modifier nonReentrant() {
        if (_lock == 2) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    error Reentrancy();

    // ===================== Campaign 追踪 =====================

    /// @notice factory dealIndex → campaign 地址
    mapping(uint256 => address) public campaigns;

    // ===================== BySig TYPEHASH 常量 =====================

    bytes32 private constant _CREATE_DEAL_TYPEHASH = keccak256(
        "CreateDealBySig(uint96 grossAmount,address verifier,uint96 verifierFee,"
        "uint96 rewardPerFollow,uint256 sigDeadline,bytes32 sigHash,"
        "uint64 target_user_id,uint48 campaignDeadline,"
        "address signer,address relayer,uint256 nonce,uint256 deadline)"
    );

    // ===================== 构造函数 =====================

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

    // ===================== Campaign 创建 =====================

    /// @notice A 创建新的 XFollowCampaign（通过 EIP-1167 clone）
    /// @param grossAmount A 存入的 USDC 总预算
    /// @param verifier_ Verifier 合约地址
    /// @param verifierFee_ 每次 claim 的 Verifier 费用
    /// @param rewardPerFollow_ 每次成功 claim 的 B 奖励
    /// @param sigDeadline Verifier 签名的 deadline
    /// @param sig Verifier 的 EIP-712 签名
    /// @param target_user_id_ 目标 Twitter user_id
    /// @param deadline_ Campaign 截止时间
    /// @return campaign 新创建的 XFollowCampaign 地址
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

    /// @notice A 创建新的 XFollowCampaign（gasless BySig 版本）
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

        // 基础验证（详细验证由 campaign.initialize 完成）
        if (grossAmount < rewardPerFollow_ + verifierFee_ + PROTOCOL_FEE) revert InsufficientBudget();

        // 1. Clone
        campaign = Clones.clone(IMPLEMENTATION);

        // 2. USDC 从 A 转入 campaign
        if (!IERC20(feeToken).transferFrom(sender, campaign, grossAmount)) revert TransferFailed();

        // 3. 初始化 clone
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

        // 4. 记录到 factory（dealIndex = campaign 序号）
        address[] memory traders = new address[](1);
        traders[0] = sender;
        address[] memory verifiers = new address[](1);
        verifiers[0] = verifier_;
        uint256 campaignIndex = _recordStart(traders, verifiers);
        campaigns[campaignIndex] = campaign;

        // 5. 平台自动发现
        emit SubContractCreated(campaign);
    }

    // ===================== IDeal 实现（Factory 层） =====================

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

    /// @notice Factory 层不提供 per-claim 验证参数，请查询具体的 campaign 子合约
    function verificationParams(uint256, uint256)
        external pure override
        returns (address, uint256, uint256, bytes memory, bytes memory)
    {
        revert("query campaign contract directly");
    }

    /// @notice Factory 不接受验证请求
    function requestVerification(uint256, uint256) external pure override {
        revert("query campaign contract directly");
    }

    /// @notice Factory 层 phase：1=Created（campaign 已部署）
    function phase(uint256 dealIndex) external view override returns (uint8) {
        if (campaigns[dealIndex] == address(0)) return 0; // NotFound
        return 1; // Created
    }

    /// @notice Factory 层 dealStatus：返回 campaign 地址是否存在
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
            "2. USDC `approve(builder address, grossAmount)` — the full budget is transferred to the campaign on creation\n"
            "3. Query `protocolFeePerClaim()` to calculate budget: grossAmount = slots * (rewardPerFollow + verifierFee + protocolFee)\n\n"
            "## After Creation\n\n"
            "- `createDeal` returns the deployed campaign contract address. Also emitted in `DealCreated` event.\n"
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
