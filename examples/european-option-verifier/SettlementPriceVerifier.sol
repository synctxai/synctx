// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../contracts/VerifierBase.sol";
import "../../contracts/IDeal.sol";
import "../../contracts/IERC20.sol";

/// @title SettlementPriceVerifier - European option settlement price verifier
/// @notice Responsible for writing the expiry settlement price on-chain and notifying the DealContract via callback.
/// @dev Since IDeal.onVerificationResult only supports int8 result, it cannot directly carry a numeric price.
///      Therefore the price is provided via a side-channel getter settlementPriceOf(...) for the DealContract to read.
contract SettlementPriceVerifier is VerifierBase {

    error PriceMustBePositive();
    error PriceAlreadySet();

    uint256 public constant MAX_SIGN_DEADLINE_SECONDS = 3600;

    address public immutable SPEC;

    mapping(bytes32 => uint256) private _settlementPrices;

    constructor(address specAddress) VerifierBase("SettlementPriceVerifier", "1") {
        require(specAddress != address(0), "spec cannot be zero");
        SPEC = specAddress;
    }

    function description() external pure override(VerifierBase) returns (string memory) {
        return
            "Verify settlement prices for European options. "
            "Reports numeric price on-chain via settlementPriceOf(). "
            "EIP-712 signed, max sign deadline 1 hour (3600s).";
    }

    function spec() external view override(VerifierBase) returns (address) {
        return SPEC;
    }

    function settlementPriceOf(
        address dealContract,
        uint256 dealIndex,
        uint256 verificationIndex
    ) external view returns (uint256) {
        return _settlementPrices[_priceKey(dealContract, dealIndex, verificationIndex)];
    }

    function reportSettlementPrice(
        address dealContract,
        uint256 dealIndex,
        uint256 verificationIndex,
        uint256 settlementPrice,
        string calldata reason,
        uint256 expectedFee
    ) external onlySigner {
        if (settlementPrice == 0) revert PriceMustBePositive();

        bytes32 key = _priceKey(dealContract, dealIndex, verificationIndex);
        if (_settlementPrices[key] != 0) revert PriceAlreadySet();
        _settlementPrices[key] = settlementPrice;

        uint256 balBefore = IERC20(feeToken).balanceOf(address(this));
        IDeal(dealContract).onVerificationResult(dealIndex, verificationIndex, 1, reason);
        if (IERC20(feeToken).balanceOf(address(this)) - balBefore < expectedFee) revert FeeNotReceived();
    }

    function reportInconclusive(
        address dealContract,
        uint256 dealIndex,
        uint256 verificationIndex,
        string calldata reason,
        uint256 expectedFee
    ) external onlySigner {
        uint256 balBefore = IERC20(feeToken).balanceOf(address(this));
        IDeal(dealContract).onVerificationResult(dealIndex, verificationIndex, 0, reason);
        if (IERC20(feeToken).balanceOf(address(this)) - balBefore < expectedFee) revert FeeNotReceived();
    }

    function reportFailure(
        address dealContract,
        uint256 dealIndex,
        uint256 verificationIndex,
        string calldata reason,
        uint256 expectedFee
    ) external onlySigner {
        uint256 balBefore = IERC20(feeToken).balanceOf(address(this));
        IDeal(dealContract).onVerificationResult(dealIndex, verificationIndex, -1, reason);
        if (IERC20(feeToken).balanceOf(address(this)) - balBefore < expectedFee) revert FeeNotReceived();
    }

    function _priceKey(
        address dealContract,
        uint256 dealIndex,
        uint256 verificationIndex
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(dealContract, dealIndex, verificationIndex));
    }
}
