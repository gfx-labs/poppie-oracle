// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";

/// @notice Plain ERC-4626 standing in for `PoppieBalanceWrapper`: the escrow hook only reads its `asset()`.
contract MockWrapper is ERC4626 {
    constructor(IERC20 token) ERC20("Wrapped", "wTKN") ERC4626(token) {}
}

/// @notice Stands in for `PoppieEulerOracle` where the escrow hook reads it: `state(asset)` only. Like the real
/// oracle, it reverts `AssetNotListed` for a token that was never set, and never lists a wrapper.
contract MockStateOracle {
    mapping(address asset => bool) public isListed;
    mapping(address asset => IPoppieEulerOracle.PriceState) internal _state;

    function setState(address asset, IPoppieEulerOracle.PriceState s) external {
        isListed[asset] = true;
        _state[asset] = s;
    }

    function state(address asset) external view returns (IPoppieEulerOracle.PriceState) {
        if (!isListed[asset]) revert IPoppieEulerOracle.AssetNotListed(asset);
        return _state[asset];
    }
}

/// @notice Stands in for `PoppieWrapperFactory` where the escrow hook reads it: the `isWrapper` registry.
contract MockWrapperFactory {
    mapping(address => bool) public isWrapper;
    mapping(address token => address) public wrapperOf;

    function register(address token, address wrapper) external {
        isWrapper[wrapper] = true;
        wrapperOf[token] = wrapper;
    }
}
