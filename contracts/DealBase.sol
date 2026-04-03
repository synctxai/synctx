// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IDeal.sol";

/// @title DealBase - Abstract base for deal contracts
/// @notice Implements IDeal. Subcontracts inherit and override all abstract methods.
/// @dev Kept intentionally lightweight — no State enum, Deal struct, or storage.
///      Different deal types have vastly different state machines and data models.
///      SECURITY: No owner, no admin, no proxy, no selfdestruct, no delegatecall.
///      Trust comes from code transparency and audit, not from privileged roles.
abstract contract DealBase is IDeal {

    // ===================== serviceMode Constants =====================

    uint8 constant MODE_TESTING = 0;
    uint8 constant MODE_OPENING = 1;
    uint8 constant MODE_CLOSED  = 2;

    // ===================== ERC165 =====================
    // ERC-165 is used by the platform to detect whether this contract implements the IDeal interface.

    bytes4 private constant _INTERFACE_ID =
        type(IDeal).interfaceId;

    /// @dev IERC165 interfaceId = bytes4(keccak256("supportsInterface(bytes4)"))
    bytes4 private constant _IERC165_ID = 0x01ffc9a7;

    /// @dev No virtual → subcontracts cannot override
    /// @notice ERC165: query if this contract implements a given interface
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == _INTERFACE_ID
            || interfaceId == _IERC165_ID;
    }

    // ===================== Interface Version =====================

    /// @dev No virtual → subcontracts cannot override
    function standard() external pure returns (uint8) {
        return 1;
    }

    // ===================== Deal Index Counter =====================

    /// @dev Next deal index, auto-incremented by _recordStart
    uint256 private _nextDealIndex;

    /// @dev Record a new deal start
    /// @param traders Array of trader addresses involved
    /// @param verifiers Array of verifier addresses (pass empty array if no verification)
    /// @return dealIndex The new deal index (pre-increment value)
    function _recordStart(address[] memory traders, address[] memory verifiers) internal returns (uint256 dealIndex) {
        dealIndex = _nextDealIndex++;
        emit DealCreated(dealIndex, traders, verifiers);
    }

    /// @dev Emit phase change event
    /// @param dealIndex The deal index
    /// @param toPhase Target phase: 2=Active, 3=Success, 4=Failed, 5=Cancelled
    function _emitPhaseChanged(uint256 dealIndex, uint8 toPhase) internal {
        emit DealPhaseChanged(dealIndex, toPhase);
    }

    /// @dev Emit status change notification
    function _emitStatusChanged(uint256 dealIndex, uint8 statusIndex) internal {
        emit DealStatusChanged(dealIndex, statusIndex);
    }

    /// @dev Emit violator marker
    function _emitViolated(uint256 dealIndex, address violator, string memory reason) internal {
        emit DealViolated(dealIndex, violator, reason);
    }

    /// @dev Emit service mode change event
    function _emitServiceModeChanged(uint8 mode) internal {
        emit ServiceModeChanged(mode);
    }

    // ===================== serviceMode Default Implementation =====================
    // Most contracts are permanently OPENING; just inherit as-is.
    // Contracts that need a TESTING state machine (e.g. EuropeanOption) override on their own.

    /// @dev Default returns OPENING — subcontracts may override
    function serviceMode() external view virtual returns (uint8) {
        return MODE_OPENING;
    }

    // ===================== Abstract Methods =====================
    // Subcontracts must override all methods below.
    // onVerificationResult defaults to revert — contracts that don't use verification need not override.

    function name() external pure virtual returns (string memory);

    function description() external pure virtual returns (string memory);

    function tags() external pure virtual returns (string[] memory);

    function version() external pure virtual returns (string memory);

    function instruction() external view virtual returns (string memory);

    function phase(uint256 dealIndex) external view virtual returns (uint8);

    function dealStatus(uint256 dealIndex) external view virtual returns (uint8);

    function dealExists(uint256 dealIndex) external view virtual returns (bool);

    function protocolFeePolicy() external view virtual returns (string memory);

    function requiredSpecs() external view virtual returns (address[] memory);

    function verificationParams(uint256 dealIndex, uint256 verificationIndex)
        external view virtual returns (
            address verifier,
            uint256 fee,
            uint256 deadline,
            bytes memory sig,
            bytes memory specParams
        );

    function requestVerification(uint256 dealIndex, uint256 verificationIndex) external virtual;

    /// @dev Must be overridden in subclass to handle verification results. Defaults to revert; contracts that don't use verification need not override.
    function onVerificationResult(uint256, uint256, int8, string calldata) external virtual {
        revert("not implemented");
    }
}
