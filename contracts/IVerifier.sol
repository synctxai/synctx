// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVerifier - Verifier contract standard interface (v3)
/// @notice All verifier contracts must implement this interface.
/// @dev check() is NOT part of IVerifier — it belongs to the VerifierSpec contract.
///      VerifierBase exposes DOMAIN_SEPARATOR (public) and owner (public) for Spec's check() to read.
interface IVerifier {

    /// @notice Submit verification result to a deal contract
    /// @param dealContract The deal contract address
    /// @param dealIndex The deal index
    /// @param verificationIndex The verification slot index
    /// @param result Verification result: positive=pass, negative=fail, 0=inconclusive
    /// @param reason Human-readable reason
    /// @param expectedFee Expected USDC fee; reverts if DealContract does not pay this amount
    function reportResult(address dealContract, uint256 dealIndex, uint256 verificationIndex, int8 result, string calldata reason, uint256 expectedFee) external;

    /// @notice Verifier instance name (for display purposes)
    function name() external view returns (string memory);

    /// @notice Verification capability description (instance-level self-description)
    function description() external view returns (string memory);

    /// @notice Contract owner
    function owner() external view returns (address);

    /// @notice Returns the business spec contract address this verifier implements
    function spec() external view returns (address);

    /// @notice EIP-712 domain separator (public for Spec's check() to read)
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice ERC-165 interface detection
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
