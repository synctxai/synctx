// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDeal - Deal Contract Standard Interface (v1)
/// @notice All deal contracts must implement this interface for unified platform recognition.
/// @dev Similar to IERC20, defines the minimal standard for deal contracts.
interface IDeal {

    // ===================== Identity =====================

    /// @notice Returns the contract name (e.g. "XQuoteDealContract")
    function name() external pure returns (string memory);

    /// @notice Returns the contract description (for platform search)
    function description() external pure returns (string memory);

    /// @notice Returns classification tags (e.g. ["x", "quote"])
    function tags() external pure returns (string[] memory);

    /// @notice Returns the specific deal contract version (e.g. "1.0.0")
    function version() external pure returns (string memory);

    /// @notice Returns the IDeal standard version number
    function standard() external pure returns (uint8);

    /// @notice ERC-165 interface detection
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);

    /// @notice Protocol fee policy description
    /// @dev Returns human-readable fee policy; contracts expose their own calculation functions for agents to call
    function protocolFeePolicy() external view returns (string memory);

    // ===================== Contract Lifecycle =====================
    // serviceMode() is a contract-level operating state, unrelated to per-deal phase/dealStatus.
    //   0 = TESTING  — accepts deals, but admin retains management privileges (can change params, can close)
    //   1 = OPENING  — params frozen, admin privileges permanently destroyed, irreversible
    //   2 = CLOSED   — no new deals accepted (existing deals continue to completion)

    /// @notice Contract-level operating state
    /// @dev 0=Testing, 1=Opening, 2=Closed
    function serviceMode() external view returns (uint8);

    /// @notice Emitted when contract operating state changes
    event ServiceModeChanged(uint8 indexed mode);

    // ===================== Guidance & Status =====================
    // instruction() is the primary entry point for agents to understand the contract.
    // phase() is the unified status for platform UI, dealStatus() is the role-aware business status code.

    /// @notice Returns the operation guide in Markdown format
    /// @dev Agents use this as primary entry point to understand the contract
    function instruction() external view returns (string memory);

    /// @notice Platform-level unified deal phase
    /// @dev 0=NotFound, 1=Pending, 2=Active, 3=Success, 4=Failed, 5=Cancelled
    ///      Pending means created but not yet active (can be skipped, going directly to Active).
    ///      Cancelled is only reachable from Pending; after Active, only Success or Failed.
    function phase(uint256 dealIndex) external view returns (uint8);

    /// @notice Business-level deal status code
    /// @dev Defined by each implementation, returns a unified detailed status code (independent of msg.sender)
    function dealStatus(uint256 dealIndex) external view returns (uint8);

    /// @notice Returns whether a deal with the given index exists
    function dealExists(uint256 dealIndex) external view returns (bool);

    // ===================== Verification =====================
    // Verification is optional. Contracts that don't need verification return an empty array from requiredSpecs().
    // verificationIndex is the positional identifier for a verification slot; a contract can have 0 to N slots.

    /// @notice Returns the required VerifierSpec address for each verification slot
    /// @dev Trader calls after selecting a Deal contract, then searches for compatible Verifiers by spec address
    function requiredSpecs() external view returns (address[] memory);

    /// @notice Returns full verification parameters for a given slot
    /// @param dealIndex The deal index
    /// @param verificationIndex The verification slot index
    /// @return verifier  The Verifier contract address for this slot
    /// @return fee       Verification fee (USDC raw value)
    /// @return deadline  Signature expiration timestamp (Unix seconds)
    /// @return sig       Verifier signer's EIP-712 signature
    /// @return specParams Business parameters (abi.encode encoded, format documented in each contract's instruction())
    function verificationParams(uint256 dealIndex, uint256 verificationIndex)
        external view returns (
            address verifier,
            uint256 fee,
            uint256 deadline,
            bytes memory sig,
            bytes memory specParams
        );

    /// @notice Trader triggers verification at a specific verification slot
    /// @param dealIndex The deal index
    /// @param verificationIndex The verification slot index
    function requestVerification(uint256 dealIndex, uint256 verificationIndex) external;

    /// @notice Verifier submits verification result (callback from Verifier contract)
    /// @param dealIndex The deal index
    /// @param verificationIndex The verification slot index
    /// @param result Verification result: positive=pass, negative=fail, 0=inconclusive
    /// @param reason Human-readable reason
    function onVerificationResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason) external;

    // ===================== Events =====================

    // --- Sub-contract events (factory pattern) ---

    /// @notice Emitted when a factory contract creates a sub-contract. Platform listens for this event to auto-discover and register new DealContracts.
    /// @dev Only needed when a contract spawns sub-contracts via factory pattern. Sub-contracts must implement IDeal.
    ///      On receiving the event, the platform calls subContract's supportsInterface() to verify,
    ///      then reads name()/description()/tags() metadata to complete registration.
    event SubContractCreated(address indexed subContract);

    // --- Lifecycle events (emitted by DealBase internal helpers) ---

    /// @notice Emitted when a new deal is created (with participant info for platform indexing)
    event DealCreated(uint256 indexed dealIndex, address[] traders, address[] verifiers);

    /// @notice Emitted when phase changes (consolidates Activated/Ended/Disputed/Cancelled)
    /// @dev 1=Pending, 2=Active, 3=Success, 4=Failed, 5=Cancelled
    ///      DealCreated implicitly enters Pending/Active; this event covers subsequent transitions.
    ///      Platform can filter by indexed phase to replace the original multiple events.
    event DealPhaseChanged(uint256 indexed dealIndex, uint8 indexed phase);

    /// @notice Emitted when a party violates the deal (marks violator and reason, emitted alongside DealPhaseChanged->Failed)
    event DealViolated(uint256 indexed dealIndex, address indexed violator, string reason);

    // --- Business status & verification events ---

    /// @notice Emitted on every business status transition
    /// @param statusIndex dealStatus base value (status code at the time of storage write)
    event DealStatusChanged(uint256 indexed dealIndex, uint8 statusIndex);

    /// @notice Emitted when a verification result is received
    event VerificationReceived(uint256 indexed dealIndex, uint256 verificationIndex, address indexed verifier, int8 result);

    /// @notice Emitted to request verification from a verifier
    /// @dev Verifier listens for this event, then reads full params via verificationParams(dealIndex, verificationIndex)
    event VerificationRequested(
        uint256 indexed dealIndex,
        uint256 verificationIndex,
        address indexed verifier
    );

    /// @notice Emitted when a settlement proposal is submitted
    event SettlementProposed(uint256 indexed dealIndex, address indexed proposer, uint256 amountToA, uint256 settlementVersion);
}
