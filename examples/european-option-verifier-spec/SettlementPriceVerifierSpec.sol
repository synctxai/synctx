// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../contracts/VerifierSpec.sol";

/// @title SettlementPriceVerifierSpec - 欧式期权结算价验证规范
/// @notice 用于验证“某个 Verifier 是否同意为指定 underlying/quote/expiry 提供结算价格”。
/// @dev SyncTx 的 onVerificationResult 只支持 int8 result，无法直接传输数值价格。
///      因此本 Spec 只负责验证签名条款；实际价格由具体 Verifier 实例在链上存储，
///      DealContract 在回调中读取 verifier.settlementPriceOf(...)。
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
