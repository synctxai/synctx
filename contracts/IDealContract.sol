// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDealContract - Deal Contract Standard Interface (v1)
/// @notice All deal contracts implement this interface for unified platform recognition.
/// @dev Similar to IERC20, defines the minimal standard for deal contracts.
interface IDealContract {

    // ===================== Identity =====================

    /// @notice Returns the contract name (e.g. "XQuoteDealContract")
    function contractName() external pure returns (string memory);

    /// @notice Returns the contract description (for platform search)
    function description() external pure returns (string memory);

    /// @notice Returns classification tags (e.g. ["x", "quote"])
    function getTags() external pure returns (string[] memory);

    /// @notice Returns the specific deal contract version (e.g. "1.0.0")
    function dealVersion() external pure returns (string memory);

    /// @notice Returns the IDealContract standard version (e.g. "1.0")
    function interfaceVersion() external pure returns (string memory);

    /// @notice ERC-165 interface detection
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);

    /// @notice Protocol fee amount (Trader reads to calculate grossAmount)
    function protocolFee() external view returns (uint96);

    // ===================== Guidance & Status =====================

    /// @notice Returns the operation guide in Markdown format
    /// @dev Agents use this as primary entry point to understand the contract
    function instruction() external view returns (string memory);

    /// @notice Universal deal status for platform-level UI
    /// @dev 0=NotFound, 1=Active, 2=Success, 3=Failed, 4=Refunding, 5=Cancelled
    function status(uint256 dealIndex) external view returns (uint8);

    /// @notice Business-specific deal status code
    /// @dev Returns detailed status code defined by each implementation
    function dealStatus(uint256 dealIndex) external view returns (uint8);

    /// @notice Returns whether a deal with the given index exists
    function dealExists(uint256 dealIndex) external view returns (bool);

    // ===================== Stats =====================

    /// @notice Total number of deals created
    function startCount() external view returns (uint256);

    /// @notice Total number of deals activated (all parties confirmed)
    function activatedCount() external view returns (uint256);

    /// @notice Total number of deals ended normally
    function endCount() external view returns (uint256);

    /// @notice Total number of deals ended with dispute
    function disputeCount() external view returns (uint256);

    // ===================== Verification =====================

    /// @notice Returns the required spec address for each verification slot
    /// @dev Trader calls after selecting DealContract, then searches Verifiers by spec address
    function getRequiredSpecs() external view returns (address[] memory);

    /// @notice Returns full verification parameters for a given slot
    /// @param dealIndex The deal index
    /// @param verificationIndex The verification slot index
    function getVerificationParams(uint256 dealIndex, uint256 verificationIndex)
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

    /// @notice Verifier submits verification result (callback from VerifierContract)
    /// @param dealIndex The deal index
    /// @param verificationIndex The verification slot index
    /// @param result Verification result: positive=pass, negative=fail, 0=inconclusive
    /// @param reason Human-readable reason
    function onReportResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason) external;

    // ===================== Events =====================

    // --- Lifecycle events (stats, emitted by DealContractBase internal tools) ---

    /// @notice Emitted when a new deal is created (startCount++)
    event DealCreated(uint256 indexed dealIndex, address[] traders, address[] verifiers);

    /// @notice Emitted when all parties have confirmed (activatedCount++)
    event DealActivated(uint256 indexed dealIndex);

    /// @notice Emitted when a deal ends normally (endCount++)
    event DealEnded(uint256 indexed dealIndex);

    /// @notice Emitted when a deal ends with dispute (disputeCount++)
    event DealDisputed(uint256 indexed dealIndex);

    /// @notice Emitted when a deal is cancelled before activation (no stats impact)
    event DealCancelled(uint256 indexed dealIndex);

    /// @notice Emitted when a party violates the deal
    event DealViolated(uint256 indexed dealIndex, address indexed violator);

    // --- Status & verification events ---

    /// @notice Emitted on every state transition
    /// @param stateIndex Business State enum value (role-independent, unlike dealStatus)
    ///        Platform uses stateIndex + instruction() to infer who needs to act
    event DealStateChanged(uint256 indexed dealIndex, uint8 stateIndex);

    /// @notice Emitted when a verification result is received
    event VerificationReceived(uint256 indexed dealIndex, uint256 verificationIndex, address indexed verifier, int8 result);

    /// @notice Emitted to request verification from a verifier
    /// @dev Verifier reads full params via getVerificationParams(dealIndex, verificationIndex)
    event VerifyRequest(
        uint256 indexed dealIndex,
        uint256 verificationIndex,
        address indexed verifier
    );
}
