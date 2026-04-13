// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IERC20Metadata.sol";

/// @title FeeFormat - human-readable ERC20 amount formatting
/// @notice Shared helper used by deal contracts' descriptor functions
///         (e.g. protocolFeePolicy) to render raw token amounts as strings.
///         Two layers of API:
///         - formatHuman(token, raw)  -> "0.1 USDC"
///         - toStr(raw)               -> "100000"
///         - formatAmount(token, raw) -> "0.1 USDC (raw 100000)" (convenience)
library FeeFormat {
    /// @notice Format a raw ERC20 amount as "{decimalValue} {symbol}", e.g. "0.1 USDC".
    function formatHuman(address token, uint256 raw) internal view returns (string memory) {
        IERC20Metadata t = IERC20Metadata(token);
        return string(abi.encodePacked(
            _formatDecimal(raw, t.decimals()), " ", t.symbol()
        ));
    }

    /// @notice uint256 -> decimal string (e.g. 100000 -> "100000").
    function toStr(uint256 v) internal pure returns (string memory) {
        return _uintToStr(v);
    }

    /// @notice Convenience: "0.1 USDC (raw 100000)".
    function formatAmount(address token, uint256 raw) internal view returns (string memory) {
        return string(abi.encodePacked(
            formatHuman(token, raw), " (raw ", _uintToStr(raw), ")"
        ));
    }

    // -------------------- internals --------------------

    function _uintToStr(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        uint256 temp = v;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits -= 1;
            buf[digits] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }

    function _formatDecimal(uint256 raw, uint8 decimals) private pure returns (string memory) {
        if (decimals == 0) return _uintToStr(raw);
        uint256 scale = 10 ** uint256(decimals);
        uint256 intPart = raw / scale;
        uint256 frac = raw % scale;
        if (frac == 0) return _uintToStr(intPart);
        bytes memory fracStr = new bytes(decimals);
        for (uint256 i = decimals; i > 0; i--) {
            fracStr[i - 1] = bytes1(uint8(48 + frac % 10));
            frac /= 10;
        }
        uint256 len = decimals;
        while (len > 0 && fracStr[len - 1] == bytes1(uint8(48))) { len--; }
        bytes memory trimmed = new bytes(len);
        for (uint256 i = 0; i < len; i++) { trimmed[i] = fracStr[i]; }
        return string(abi.encodePacked(_uintToStr(intPart), ".", trimmed));
    }
}
