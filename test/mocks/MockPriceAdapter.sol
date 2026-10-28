// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "euler-price-oracle/interfaces/IPriceOracle.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Fixed-price Euler adapter for harness tests. Price is 18-decimal USD per whole `base` token, the
/// same scale as the real PoppieEulerAdapter. Stands in for the adapter and for the USDC/USD fixed-rate oracle.
contract MockPriceAdapter is IPriceOracle {
    string public constant override name = "MockPriceAdapter";

    mapping(address base => uint256) public priceOf;

    function setPrice(address base, uint256 price) external {
        priceOf[base] = price;
    }

    function getQuote(uint256 inAmount, address base, address) public view override returns (uint256) {
        return inAmount * priceOf[base] / 10 ** IDecimals(base).decimals();
    }

    function getQuotes(uint256 inAmount, address base, address quote)
        external
        view
        override
        returns (uint256, uint256)
    {
        uint256 out = getQuote(inAmount, base, quote);
        return (out, out);
    }
}
