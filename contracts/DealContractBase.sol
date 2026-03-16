// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IDealContract.sol";

/// @title DealContractBase - Abstract base for deal contracts
/// @notice Implements IDealContract. Subcontracts inherit and override all methods.
/// @dev Kept intentionally lightweight — no State enum, Deal struct, or storage.
///      Different deal types have vastly different state machines and data models.
///      SECURITY: No owner, no admin, no proxy, no selfdestruct, no delegatecall.
///      Trust comes from code transparency and audit, not from privileged roles.
abstract contract DealContractBase is IDealContract {

    // ===================== ERC165 =====================

    bytes4 private constant _INTERFACE_ID =
        type(IDealContract).interfaceId;

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
    function interfaceVersion() external pure returns (string memory) {
        return "1.0";
    }

    // ===================== Stats (tamper-resistant) =====================

    /// @dev private → subcontracts cannot read or write directly
    uint256 private _startCount;
    uint256 private _activatedCount;
    uint256 private _endCount;
    uint256 private _disputeCount;

    /// @dev Record a new deal start
    /// @param traders Array of trader addresses involved
    /// @param verifiers Array of verifier addresses involved
    /// @return dealIndex The new deal index (pre-increment value)
    function _recordStart(address[] memory traders, address[] memory verifiers) internal returns (uint256 dealIndex) {
        dealIndex = _startCount++;
        emit DealCreated(dealIndex, traders, verifiers);
    }

    /// @dev Record deal activation (all parties confirmed)
    /// @param dealIndex The deal index
    function _recordActivated(uint256 dealIndex) internal {
        _activatedCount++;
        emit DealActivated(dealIndex);
    }

    /// @param dealIndex The deal index
    function _recordEnd(uint256 dealIndex) internal {
        _endCount++;
        emit DealEnded(dealIndex);
    }

    function _recordDispute(uint256 dealIndex) internal {
        _disputeCount++;
        emit DealDisputed(dealIndex);
    }

    /// @dev Record deal cancellation (before activation, no stats impact)
    /// @param dealIndex The deal index
    function _recordCancelled(uint256 dealIndex) internal {
        emit DealCancelled(dealIndex);
    }

    /// @dev Emit state change notification
    function _emitStateChanged(uint256 dealIndex, uint8 stateIndex) internal {
        emit DealStateChanged(dealIndex, stateIndex);
    }

    /// @dev Emit violator marker
    function _emitViolated(uint256 dealIndex, address violator) internal {
        emit DealViolated(dealIndex, violator);
    }

    /// @dev No virtual → subcontracts cannot tamper with the return value
    function startCount() external view returns (uint256) {
        return _startCount;
    }

    function activatedCount() external view returns (uint256) {
        return _activatedCount;
    }

    function endCount() external view returns (uint256) {
        return _endCount;
    }

    function disputeCount() external view returns (uint256) {
        return _disputeCount;
    }

    // ===================== Abstract methods =====================

    function contractName() external pure virtual returns (string memory);

    function description() external pure virtual returns (string memory);

    function getTags() external pure virtual returns (string[] memory);

    function dealVersion() external pure virtual returns (string memory);

    function instruction() external view virtual returns (string memory);

    function status(uint256 dealIndex) external view virtual returns (uint8);

    function dealStatus(uint256 dealIndex) external view virtual returns (uint8);

    function dealExists(uint256 dealIndex) external view virtual returns (bool);

    function protocolFee() external view virtual returns (uint96);

    function getRequiredSpecs() external view virtual returns (address[] memory);

    function getVerificationParams(uint256 dealIndex, uint256 verificationIndex)
        external view virtual returns (
            address verifier,
            uint256 fee,
            uint256 deadline,
            bytes memory sig,
            bytes memory specParams
        );

    function requestVerification(uint256 dealIndex, uint256 verificationIndex) external virtual;

    /// @dev Must be overridden in subclass to handle verification results.
    function onReportResult(uint256, uint256, int8, string calldata) external virtual {
        revert("not implemented");
    }
}
