// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title PackedPrices
/// @notice The packed push format of `keeperPushPacked` (CONTRACT_SPEC.md section 3.1):
/// 14 bytes per asset, `uint16 id | uint96 price`, big-endian, entries concatenated with no header.
/// `id` is the compact id the oracle assigns at listing; `price` is 18-decimal USD per whole token.
library PackedPrices {
    uint256 internal constant ENTRY_SIZE = 14;

    /// @notice Encodes one entry.
    function encode(uint16 id, uint96 price) internal pure returns (bytes memory) {
        return abi.encodePacked(id, price);
    }

    /// @notice Number of whole entries in `data`. Check `isValidLength` first.
    function entryCount(bytes calldata data) internal pure returns (uint256) {
        return data.length / ENTRY_SIZE;
    }

    /// @notice True when `data.length` is a multiple of 14.
    function isValidLength(bytes calldata data) internal pure returns (bool) {
        return data.length % ENTRY_SIZE == 0;
    }

    /// @notice Decodes entry `index`. The caller must have checked `isValidLength` and `index < entryCount`.
    function decode(bytes calldata data, uint256 index) internal pure returns (uint16 id, uint96 price) {
        uint256 offset = index * ENTRY_SIZE;
        id = uint16(bytes2(data[offset:offset + 2]));
        price = uint96(bytes12(data[offset + 2:offset + ENTRY_SIZE]));
    }
}
