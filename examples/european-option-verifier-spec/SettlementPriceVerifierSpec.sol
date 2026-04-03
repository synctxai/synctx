// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../contracts/VerifierSpec.sol";

/// @title SettlementPriceVerifierSpec - European option settlement price verification spec
/// @notice Verifies that a Verifier agrees to provide a settlement price for a given underlying/quote/expiry.
/// @dev SyncTx's onVerificationResult only supports int8 result, which cannot directly carry a numeric price.
///      Therefore this Spec only verifies signature terms; the actual price is stored on-chain by the
///      specific Verifier instance, and the DealContract reads it via verifier.settlementPriceOf(...) in the callback.
contract SettlementPriceVerifierSpec is VerifierSpec {

    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(address underlying,address quoteToken,uint256 expiry,uint256 settlementWindow,uint256 fee,uint256 deadline)"
    );

    function name() external pure override returns (string memory) {
        return "Settlement Price Verifier Spec";
    }

    function version() external pure override returns (string memory) {
        return "1.0";
    }

    function description() external pure override returns (string memory) {
        return
            "Settlement price verification spec for European options. "
            "Result type: Boolean-like transport (1=price available, 0=inconclusive, -1=failed). "
            "The numeric settlement price is NOT carried in int8 result; it is stored on the verifier instance "
            "and must be read by the deal contract via settlementPriceOf(dealContract, dealIndex, verificationIndex). "
            "check(underlying, quoteToken, expiry, settlementWindow). "
            "specParams: abi.encode(underlying, quoteToken, expiry, settlementWindow).";
    }

    function check(
        address verifierInstance,
        address underlying,
        address quoteToken,
        uint256 expiry,
        uint256 settlementWindow,
        uint256 fee,
        uint256 deadline,
        bytes calldata sig
    ) external view returns (address) {
        bytes32 structHash = keccak256(
            abi.encode(
                VERIFY_TYPEHASH,
                underlying,
                quoteToken,
                expiry,
                settlementWindow,
                fee,
                deadline
            )
        );

        return _recoverEIP712Signer(verifierInstance, structHash, deadline, sig);
    }
}
