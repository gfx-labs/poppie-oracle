// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EVKOps} from "../../src/peripheral/interfaces/IEVaultHook.sol";

/// @dev Models the EVK hook dispatch as described in plan2 A30 (unverified against EVK):
///      a hooked op calls the target with `msg.data ++ account`; an unhooked op never calls it;
///      a hooked op with target 0 is disabled. `batch` models an atomic EVC batch: ops run as the
///      caller, then the deferred status check runs once; any revert undoes the whole batch.
contract MockVault {
    error OperationDisabled();

    address public hookTarget;
    uint32 public hookedOps;
    uint256 public totalBorrows;
    mapping(address => uint256) public debtOf;
    mapping(address => uint256) public balanceOf;
    address public asset;
    address internal _batchAccount;

    constructor(address asset_) {
        asset = asset_;
    }

    function setHookConfig(address target, uint32 ops) external {
        hookTarget = target;
        hookedOps = ops;
    }

    function hookConfig() external view returns (address, uint32) {
        return (hookTarget, hookedOps);
    }

    function setTotalBorrows(uint256 v) external {
        totalBorrows = v;
    }

    function setDebt(address a, uint256 v) external {
        debtOf[a] = v;
    }

    function batch(bytes[] calldata calls) external {
        _batchAccount = msg.sender;
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(this).call(calls[i]);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        _batchAccount = address(0);
        _hook(EVKOps.OP_VAULT_STATUS_CHECK, abi.encodeWithSignature("checkVaultStatus()"), msg.sender);
    }

    function _sender() internal view returns (address) {
        return msg.sender == address(this) ? _batchAccount : msg.sender;
    }

    function _hook(uint32 op, bytes memory data, address account) internal {
        if (hookedOps & op == 0) return;
        if (hookTarget == address(0)) revert OperationDisabled();
        (bool ok, bytes memory ret) = hookTarget.call(abi.encodePacked(data, account));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    // ── hub ops ─────────────────────────────────────────────────────────
    function borrow(uint256 amount, address) external returns (uint256) {
        _hook(EVKOps.OP_BORROW, msg.data, _sender());
        if (amount != type(uint256).max) {
            totalBorrows += amount;
            debtOf[_sender()] += amount;
        }
        return amount;
    }

    function repay(uint256 amount, address receiver) external returns (uint256) {
        _hook(EVKOps.OP_REPAY, msg.data, _sender());
        uint256 d = debtOf[receiver];
        if (amount > d) amount = d;
        debtOf[receiver] = d - amount;
        totalBorrows -= amount;
        return amount;
    }

    /// @dev Liquidation moves debt to the liquidator without raising totalBorrows (A30 h).
    function liquidate(address violator, address, uint256 repayAssets, uint256) external {
        _hook(EVKOps.OP_LIQUIDATE, msg.data, _sender());
        uint256 d = debtOf[violator];
        if (repayAssets > d) repayAssets = d;
        debtOf[violator] = d - repayAssets;
        debtOf[_sender()] += repayAssets;
    }

    function flashLoan(uint256, bytes calldata) external {
        _hook(EVKOps.OP_FLASHLOAN, msg.data, _sender());
    }

    function touch() external {
        _hook(EVKOps.OP_TOUCH, msg.data, _sender());
    }

    // ── share ops ───────────────────────────────────────────────────────
    function deposit(uint256 amount, address receiver) external returns (uint256) {
        _hook(EVKOps.OP_DEPOSIT, msg.data, _sender());
        balanceOf[receiver] += amount;
        return amount;
    }

    function mint(uint256 amount, address receiver) external returns (uint256) {
        _hook(EVKOps.OP_MINT, msg.data, _sender());
        balanceOf[receiver] += amount;
        return amount;
    }

    function skim(uint256 amount, address receiver) external returns (uint256) {
        _hook(EVKOps.OP_SKIM, msg.data, _sender());
        balanceOf[receiver] += amount;
        return amount;
    }

    function withdraw(uint256 amount, address, address owner) external returns (uint256) {
        _hook(EVKOps.OP_WITHDRAW, msg.data, _sender());
        balanceOf[owner] -= amount;
        return amount;
    }

    function redeem(uint256 amount, address, address owner) external returns (uint256) {
        _hook(EVKOps.OP_REDEEM, msg.data, _sender());
        balanceOf[owner] -= amount;
        return amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _hook(EVKOps.OP_TRANSFER, msg.data, _sender());
        balanceOf[_sender()] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _hook(EVKOps.OP_TRANSFER, msg.data, _sender());
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFromMax(address from, address to) external returns (bool) {
        _hook(EVKOps.OP_TRANSFER, msg.data, _sender());
        balanceOf[to] += balanceOf[from];
        balanceOf[from] = 0;
        return true;
    }

    /// @dev Deferred vault status check, run once at the end of a batch.
    function statusCheck() external {
        _hook(EVKOps.OP_VAULT_STATUS_CHECK, abi.encodeWithSignature("checkVaultStatus()"), msg.sender);
    }
}

contract MockEVC {
    mapping(address => address) internal _owner;
    bool public isControlCollateralInProgress;

    function setOwner(address account, address owner) external {
        _owner[account] = owner;
    }

    function setControlCollateral(bool v) external {
        isControlCollateralInProgress = v;
    }

    function getAccountOwner(address account) external view returns (address) {
        return _owner[account];
    }
}

contract MockSanctions {
    mapping(address => bool) public isSanctioned;

    function set(address a, bool v) external {
        isSanctioned[a] = v;
    }
}

contract MockFactory {
    mapping(address => bool) public isProxy;

    function set(address a, bool v) external {
        isProxy[a] = v;
    }
}
