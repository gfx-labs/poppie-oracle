// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {PackedPrices} from "../../src/oracle/PackedPrices.sol";
import {MS_OPS, K_PRICE, K_CONFIRM, K_TIGHTEN} from "../../src/access/Roles.sol";

import {PoppieEulerOracle} from "../../src/oracle/PoppieEulerOracle.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {OracleFixture} from "../harness/OracleFixture.sol";

/// @notice Unit tests for `PoppieEulerOracle` (CONTRACT_SPEC.md section 3.1). The default setup lists
/// A (18 dec, blue chip, h 10%), B (6 dec, M1, h 15%), C (8 dec, M3, h 30%), with n = 3, spacing 10 min,
/// max age 1 h.
contract PoppieEulerOracleTest is OracleFixture {
    address internal a;
    uint256 internal constant SPACING = 10 minutes;

    function setUp() public override {
        super.setUp();
        a = address(tokenA);
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    // -- Defaults and listing --------------------------------------------------------------------

    function test_defaults() public view {
        assertEq(oracle.maxPriceAge(), 1 hours);
        assertEq(oracle.n(), 3);
        assertEq(oracle.minPendingSpacing(), 10 minutes);
        assertEq(oracle.haircutBps(IPoppieEulerOracle.PriceClass.BlueChip), 1000);
        assertEq(oracle.haircutBps(IPoppieEulerOracle.PriceClass.M1), 1500);
        assertEq(oracle.haircutBps(IPoppieEulerOracle.PriceClass.M2), 2000);
        assertEq(oracle.haircutBps(IPoppieEulerOracle.PriceClass.M3), 3000);
    }

    function test_listAssets_assignsSequentialIdsAndReadsDecimals() public view {
        assertEq(oracle.assetCount(), 3);
        assertEq(oracle.assetId(address(tokenA)), 0);
        assertEq(oracle.assetId(address(tokenB)), 1);
        assertEq(oracle.assetId(address(tokenC)), 2);
        assertEq(oracle.assetById(0), address(tokenA));
        assertEq(oracle.assetById(2), address(tokenC));
        assertTrue(oracle.isListed(address(tokenB)));
        IPoppieEulerOracle.AssetData memory d = _data(address(tokenB));
        assertEq(d.decimals, 6);
        assertEq(uint8(d.priceClass), uint8(IPoppieEulerOracle.PriceClass.M1));
        assertTrue(d.listed);
        assertEq(d.id, 1);
        assertEq(d.lastPrice, 0);
    }

    function test_listAssets_emitsEvent() public {
        MockERC20 t = new MockERC20("D", "D", 12);
        address[] memory ts = new address[](1);
        ts[0] = address(t);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](1);
        cs[0] = IPoppieEulerOracle.PriceClass.M2;
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IPoppieEulerOracle.AssetListed(address(t), 3, IPoppieEulerOracle.PriceClass.M2, 12);
        vm.prank(ops);
        oracle.listAssets(ts, cs);
    }

    function test_listAssets_acceptsDecimals18AndRejectsAbove() public {
        MockERC20 ok = new MockERC20("ok", "ok", 18);
        _list(address(ok), IPoppieEulerOracle.PriceClass.M2);
        MockERC20 zero = new MockERC20("z", "z", 0);
        _list(address(zero), IPoppieEulerOracle.PriceClass.M2);

        MockERC20 bad = new MockERC20("bad", "bad", 19);
        address[] memory ts = new address[](1);
        ts[0] = address(bad);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](1);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.DecimalsTooHigh.selector, 19));
        oracle.listAssets(ts, cs);
    }

    function testFuzz_listAssets_decimalsBound(uint8 dec) public {
        MockERC20 t = new MockERC20("t", "t", dec);
        address[] memory ts = new address[](1);
        ts[0] = address(t);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](1);
        vm.prank(ops);
        if (dec > 18) vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.DecimalsTooHigh.selector, dec));
        oracle.listAssets(ts, cs);
        assertEq(oracle.isListed(address(t)), dec <= 18);
    }

    function test_listAssets_rejectsDuplicateZeroAndMismatch() public {
        address[] memory ts = new address[](1);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](1);

        ts[0] = a;
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetAlreadyListed.selector, a));
        oracle.listAssets(ts, cs);

        ts[0] = address(0);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        oracle.listAssets(ts, cs);

        // Duplicate inside one batch.
        MockERC20 t = new MockERC20("t", "t", 18);
        address[] memory two = new address[](2);
        two[0] = address(t);
        two[1] = address(t);
        IPoppieEulerOracle.PriceClass[] memory two_c = new IPoppieEulerOracle.PriceClass[](2);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetAlreadyListed.selector, address(t)));
        oracle.listAssets(two, two_c);

        vm.prank(ops);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.listAssets(two, cs);
    }

    function test_listAssets_rejectsNonTokens() public {
        address[] memory ts = new address[](1);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](1);
        ts[0] = makeAddr("eoa");
        vm.prank(ops);
        vm.expectRevert();
        oracle.listAssets(ts, cs);
    }

    function test_listAssets_onlyOps() public {
        address[] memory ts = new address[](0);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](0);
        address[3] memory others = [keeper, confirmer, admin];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(_unauthorized(others[i], MS_OPS));
            oracle.listAssets(ts, cs);
        }
    }

    function test_listAssets_tooManyAssets() public {
        // `_tokens` is the fifth storage slot (roles, params, hot, pending, tokens): fake a full registry.
        vm.store(address(oracle), bytes32(uint256(4)), bytes32(uint256(65_536)));
        assertEq(oracle.assetCount(), 65_536);
        MockERC20 t = new MockERC20("t", "t", 18);
        address[] memory ts = new address[](1);
        ts[0] = address(t);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](1);
        vm.prank(ops);
        vm.expectRevert(IPoppieEulerOracle.TooManyAssets.selector);
        oracle.listAssets(ts, cs);
    }

    function test_listAssets_lastIdIsAllowed() public {
        vm.store(address(oracle), bytes32(uint256(4)), bytes32(uint256(65_535)));
        MockERC20 t = new MockERC20("t", "t", 18);
        _list(address(t), IPoppieEulerOracle.PriceClass.M1);
        assertEq(oracle.assetId(address(t)), 65_535);
    }

    function test_unlistedAssetViewsRevert() public {
        address x = makeAddr("x");
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, x));
        oracle.state(x);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, x));
        oracle.getQuoteData(x);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, x));
        oracle.assetId(x);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.UnknownAssetId.selector, 3));
        oracle.assetById(3);
        assertFalse(oracle.isListed(x));
        assertFalse(oracle.getAssetData(x).listed);
    }

    // -- First price: only K_CONFIRM ------------------------------------------------------------

    function test_listedAssetWithoutAPriceIsClosed() public view {
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Closed));
        IPoppieEulerOracle.QuoteData memory q = oracle.getQuoteData(a);
        assertEq(q.lastPrice, 0);
        assertEq(q.pendingPrice, 0);
        assertEq(q.haircutBps, 1000);
        assertEq(q.decimals, 18);
    }

    function test_firstPush_isPendingNotLive() public {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IPoppieEulerOracle.PricePending(a, _price(100), 1, 1);
        _push(a, _price(100));
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.lastPrice, 0);
        assertEq(d.pendingPrice, _price(100));
        assertEq(d.pendingCount, 1);
        assertEq(d.pendingDir, 1);
        assertEq(d.pendingTs, T0);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
    }

    function test_firstPrice_neverGoesLiveByPersistence() public {
        // Many pushes, well spaced, same direction, any n: still pending, count stays 1.
        for (uint256 i; i < 20; ++i) {
            _push(a, _price(100 + i));
            vm.warp(block.timestamp + SPACING);
            _pushPacked(a, uint96(_price(100 + i)));
            vm.warp(block.timestamp + SPACING);
        }
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.lastPrice, 0);
        assertEq(d.pendingCount, 1);
        assertEq(d.pendingPrice, _price(119));
    }

    function test_firstPush_refreshesPendingPriceWithoutSpacing() public {
        _push(a, _price(100));
        _push(a, _price(101));
        assertEq(_data(a).pendingPrice, _price(101));
        assertEq(_data(a).pendingCount, 1);
    }

    function test_confirm_firstPriceGoesLive() public {
        _push(a, _price(100));
        vm.expectEmit(true, false, true, true, address(oracle));
        emit IPoppieEulerOracle.PriceConfirmed(a, _price(100), confirmer);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IPoppieEulerOracle.PriceLive(a, _price(100));
        _confirm(a, _price(100));
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.lastPrice, _price(100));
        assertEq(d.lastPriceTs, T0);
        assertEq(d.pendingCount, 0);
        assertEq(d.pendingDir, 0);
        assertEq(d.pendingPrice, 0);
        assertEq(d.pendingTs, 0);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));
    }

    // -- In-bound pushes -------------------------------------------------------------------------

    function test_pushWithinBound_goesLiveBothDirectionsAndAtTheEdge() public {
        _goLive(a, _price(100));
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IPoppieEulerOracle.PriceLive(a, _price(110));
        _push(a, _price(110)); // exactly +h
        assertEq(_data(a).lastPrice, _price(110));
        _push(a, _price(99)); // 99 is within 10% of 110 (bound 99)
        assertEq(_data(a).lastPrice, _price(99));
        assertEq(_data(a).lastPriceTs, block.timestamp);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));
    }

    function test_pushJustBeyondBound_isPending() public {
        _goLive(a, _price(100));
        _push(a, _price(110) + 1);
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.lastPrice, _price(100));
        assertEq(d.pendingPrice, _price(110) + 1);
        assertEq(d.pendingCount, 1);
        assertEq(d.pendingDir, 1);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));

        _goLive(address(tokenB), _price(100));
        _push(address(tokenB), _price(85) - 1);
        assertEq(_data(address(tokenB)).pendingDir, -1);
    }

    function test_pushWithinBound_resetsPending() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        assertEq(_data(a).pendingCount, 1);
        vm.warp(block.timestamp + 1);
        _push(a, _price(105)); // back within the bound of L
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.lastPrice, _price(105));
        assertEq(d.pendingCount, 0);
        assertEq(d.pendingDir, 0);
        assertEq(d.pendingPrice, 0);
        assertEq(d.pendingTs, 0);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));
    }

    function test_pushWithinBound_resetsPendingEvenInsideSpacing() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        _push(a, _price(101)); // same block, inside spacing: the in-bound rule comes first
        assertEq(_data(a).pendingCount, 0);
        assertEq(_data(a).lastPrice, _price(101));
    }

    // -- n-push fallback -------------------------------------------------------------------------

    function test_persistence_promotesAfterNSpacedPushes() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.warp(block.timestamp + SPACING);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IPoppieEulerOracle.PricePending(a, _price(151), 2, 1);
        _push(a, _price(151));
        assertEq(_data(a).pendingCount, 2);
        assertEq(_data(a).lastPrice, _price(100));
        vm.warp(block.timestamp + SPACING);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IPoppieEulerOracle.PricePromotedByPersistence(a, _price(152));
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IPoppieEulerOracle.PriceLive(a, _price(152));
        _push(a, _price(152));
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.lastPrice, _price(152));
        assertEq(d.lastPriceTs, block.timestamp);
        assertEq(d.pendingCount, 0);
        assertEq(d.pendingPrice, 0);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));
    }

    function test_persistence_downwardAlso() public {
        _goLive(a, _price(100));
        for (uint256 i; i < 3; ++i) {
            _push(a, _price(50 - i));
            vm.warp(block.timestamp + SPACING);
        }
        assertEq(_data(a).lastPrice, _price(48));
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));
    }

    function test_persistence_pushInsideSpacingIsIgnored() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.warp(block.timestamp + SPACING - 1);
        _push(a, _price(160)); // ignored: no state change at all
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.pendingCount, 1);
        assertEq(d.pendingPrice, _price(150));
        assertEq(d.pendingTs, T0);
        // Exactly at the spacing it counts.
        vm.warp(block.timestamp + 1);
        _push(a, _price(160));
        assertEq(_data(a).pendingCount, 2);
        assertEq(_data(a).pendingPrice, _price(160));
        assertEq(_data(a).pendingTs, block.timestamp);
    }

    function test_persistence_cannotPromoteInOneBlockOrOneBatch() public {
        _goLive(a, _price(100));
        address[] memory as_ = new address[](10);
        uint128[] memory ps = new uint128[](10);
        for (uint256 i; i < 10; ++i) {
            as_[i] = a;
            ps[i] = _price(150 + i);
        }
        vm.prank(keeper);
        oracle.keeperPushPrices(as_, ps);
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.lastPrice, _price(100));
        assertEq(d.pendingCount, 1);
        assertEq(d.pendingPrice, _price(150));

        // Same through the packed format.
        bytes memory packed;
        for (uint256 i; i < 10; ++i) {
            packed = bytes.concat(packed, PackedPrices.encode(0, uint96(_price(170 + i))));
        }
        vm.prank(keeper);
        oracle.keeperPushPacked(packed);
        assertEq(_data(a).pendingCount, 1);
        assertEq(_data(a).lastPrice, _price(100));
    }

    function test_persistence_directionFlipRestartsCount() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.warp(block.timestamp + SPACING);
        _push(a, _price(151));
        assertEq(_data(a).pendingCount, 2);
        vm.warp(block.timestamp + SPACING);
        _push(a, _price(50)); // beyond the bound the other way
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertEq(d.pendingCount, 1);
        assertEq(d.pendingDir, -1);
        assertEq(d.pendingPrice, _price(50));
        assertEq(d.lastPrice, _price(100));
    }

    function test_persistence_inBoundPushBetweenResetsTheCount() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.warp(block.timestamp + SPACING);
        _push(a, _price(151));
        vm.warp(block.timestamp + SPACING);
        _push(a, _price(100)); // within the bound: resets
        vm.warp(block.timestamp + SPACING);
        _push(a, _price(150));
        assertEq(_data(a).pendingCount, 1);
        assertEq(_data(a).lastPrice, _price(100));
    }

    function test_persistence_usesCurrentN() public {
        vm.prank(ops);
        oracle.setN(2);
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.warp(block.timestamp + SPACING);
        _push(a, _price(150));
        assertEq(_data(a).lastPrice, _price(150));

        vm.prank(ops);
        oracle.setN(5);
        _push(a, _price(300));
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + SPACING);
            _push(a, _price(300));
        }
        assertEq(_data(a).pendingCount, 4);
        assertEq(_data(a).lastPrice, _price(150));
        vm.warp(block.timestamp + SPACING);
        _push(a, _price(300));
        assertEq(_data(a).lastPrice, _price(300));
    }

    function test_persistence_countsWhileStaleToo() public {
        // Staleness closes the market but does not reset a pending count (spec: only an in-bound push does).
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.warp(block.timestamp + 2 hours);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Closed));
        _push(a, _price(150));
        assertEq(_data(a).pendingCount, 2);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
    }

    // -- Confirm ---------------------------------------------------------------------------------

    function test_confirm_promotesPendingAfterAMove() public {
        _goLive(a, _price(100));
        vm.warp(block.timestamp + 5);
        _push(a, _price(150));
        vm.warp(block.timestamp + 30 minutes);
        _confirm(a, _price(150));
        assertEq(_data(a).lastPrice, _price(150));
        assertEq(_data(a).lastPriceTs, block.timestamp);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));
    }

    function test_confirm_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.NothingPending.selector, a));
        vm.prank(confirmer);
        oracle.confirm(a, 1);

        _goLive(a, _price(100));
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.NothingPending.selector, a));
        vm.prank(confirmer);
        oracle.confirm(a, _price(100));

        _push(a, _price(150));
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.PendingPriceMismatch.selector, a, _price(150), _price(151))
        );
        vm.prank(confirmer);
        oracle.confirm(a, _price(151));

        // Stale: exactly maxPriceAge is still fine, one second more is not.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.PendingPriceStale.selector, a));
        vm.prank(confirmer);
        oracle.confirm(a, _price(150));

        address x = makeAddr("x");
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, x));
        vm.prank(confirmer);
        oracle.confirm(x, 1);
    }

    function test_confirm_atExactlyMaxPriceAge() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.warp(block.timestamp + 1 hours);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
        _confirm(a, _price(150));
        assertEq(_data(a).lastPrice, _price(150));
    }

    function test_confirm_revertsWhilePaused() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        _pause(a);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, a));
        vm.prank(confirmer);
        oracle.confirm(a, _price(150));
    }

    function test_confirm_onlyConfirmer() public {
        address[3] memory others = [keeper, ops, admin];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(_unauthorized(others[i], K_CONFIRM));
            oracle.confirm(a, 1);
            vm.prank(others[i]);
            vm.expectRevert(_unauthorized(others[i], K_CONFIRM));
            oracle.confirmBatch(new address[](0), new uint128[](0));
        }
    }

    function test_confirmBatch_allOrNothing() public {
        _push(a, _price(100));
        _push(address(tokenB), _price(200));
        _push(address(tokenC), _price(300));
        address[] memory as_ = new address[](3);
        uint128[] memory ps = new uint128[](3);
        as_[0] = a;
        as_[1] = address(tokenB);
        as_[2] = address(tokenC);
        ps[0] = _price(100);
        ps[1] = _price(200);
        ps[2] = _price(301); // wrong
        vm.prank(confirmer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieEulerOracle.PendingPriceMismatch.selector, address(tokenC), _price(300), _price(301)
            )
        );
        oracle.confirmBatch(as_, ps);
        assertEq(_data(a).lastPrice, 0);
        assertEq(_data(address(tokenB)).lastPrice, 0);

        ps[2] = _price(300);
        vm.prank(confirmer);
        oracle.confirmBatch(as_, ps);
        assertEq(_data(a).lastPrice, _price(100));
        assertEq(_data(address(tokenB)).lastPrice, _price(200));
        assertEq(_data(address(tokenC)).lastPrice, _price(300));

        vm.prank(confirmer);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.confirmBatch(as_, new uint128[](2));
    }

    // -- Push access, validity, formats ----------------------------------------------------------

    function test_push_onlyKeeper() public {
        address[] memory as_ = new address[](1);
        as_[0] = a;
        uint128[] memory ps = new uint128[](1);
        ps[0] = 1;
        address[4] memory others = [confirmer, ops, admin, makeAddr("rando")];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(_unauthorized(others[i], K_PRICE));
            oracle.keeperPushPrices(as_, ps);
            vm.prank(others[i]);
            vm.expectRevert(_unauthorized(others[i], K_PRICE));
            oracle.keeperPushPacked(hex"");
        }
    }

    function test_push_reverts() public {
        address[] memory as_ = new address[](1);
        uint128[] memory ps = new uint128[](1);
        as_[0] = a;
        ps[0] = 0;
        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.InvalidPrice.selector);
        oracle.keeperPushPrices(as_, ps);

        ps[0] = 1;
        as_[0] = makeAddr("x");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, as_[0]));
        oracle.keeperPushPrices(as_, ps);

        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.keeperPushPrices(as_, new uint128[](2));

        _pause(a);
        as_[0] = a;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, a));
        oracle.keeperPushPrices(as_, ps);
    }

    function test_pushPacked_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.InvalidPackedLength.selector, 13));
        oracle.keeperPushPacked(new bytes(13));

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.UnknownAssetId.selector, 3));
        oracle.keeperPushPacked(PackedPrices.encode(3, 1));

        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.InvalidPrice.selector);
        oracle.keeperPushPacked(PackedPrices.encode(0, 0));

        _pause(a);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, a));
        oracle.keeperPushPacked(PackedPrices.encode(0, 1));

        // An empty payload is a no-op.
        vm.prank(keeper);
        oracle.keeperPushPacked(hex"");
    }

    function test_pushPacked_matchesAbiPush() public {
        // Two oracles with the same listing, the same sequence, one per format: identical records throughout.
        PoppieEulerOracleHelper o2 = new PoppieEulerOracleHelper(admin, keeper, confirmer, ops);
        address[] memory ts = new address[](3);
        ts[0] = a;
        ts[1] = address(tokenB);
        ts[2] = address(tokenC);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](3);
        cs[1] = IPoppieEulerOracle.PriceClass.M1;
        cs[2] = IPoppieEulerOracle.PriceClass.M3;
        vm.prank(ops);
        o2.listAssets(ts, cs);

        uint128[10] memory seq = [
            _price(100),
            _price(100),
            _price(105),
            _price(160),
            _price(160),
            _price(161),
            _price(162),
            _price(90),
            _price(95),
            _price(300)
        ];
        uint256[10] memory dts = [uint256(0), 0, 1, 60, SPACING, SPACING, SPACING, 3, 20 minutes, 2 hours];
        for (uint256 i; i < seq.length; ++i) {
            vm.warp(block.timestamp + dts[i]);
            _push(a, seq[i]);
            vm.prank(keeper);
            o2.keeperPushPacked(PackedPrices.encode(0, uint96(seq[i])));
            if (i == 1) {
                _confirm(a, seq[i]);
                vm.prank(confirmer);
                o2.confirm(a, seq[i]);
            }
            assertEq(abi.encode(oracle.getAssetData(a)), abi.encode(o2.getAssetData(a)), "records differ");
            assertEq(uint8(oracle.state(a)), uint8(o2.state(a)));
        }
    }

    function test_pushPacked_batchOfManyAssets() public {
        bytes memory packed = bytes.concat(
            PackedPrices.encode(0, uint96(_price(10))),
            PackedPrices.encode(1, uint96(_price(20))),
            PackedPrices.encode(2, uint96(_price(30)))
        );
        vm.prank(keeper);
        oracle.keeperPushPacked(packed);
        assertEq(_data(a).pendingPrice, _price(10));
        assertEq(_data(address(tokenB)).pendingPrice, _price(20));
        assertEq(_data(address(tokenC)).pendingPrice, _price(30));
    }

    function test_pushPacked_maxPackedPrice() public {
        _pushPacked(a, type(uint96).max);
        assertEq(_data(a).pendingPrice, type(uint96).max);
    }

    function test_push_abiAcceptsUint128Max() public {
        _push(a, type(uint128).max);
        assertEq(_data(a).pendingPrice, type(uint128).max);
        _confirm(a, type(uint128).max);
        // The bound arithmetic does not overflow at the extreme.
        vm.warp(block.timestamp + 1);
        _push(a, 1);
        assertEq(_data(a).pendingPrice, 1);
    }

    // -- Pause and unpause -----------------------------------------------------------------------

    function test_pause_keepsLastPriceAndCloses() public {
        _goLive(a, _price(100));
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IPoppieEulerOracle.AssetPaused(a, keeper);
        _pause(a);
        IPoppieEulerOracle.AssetData memory d = _data(a);
        assertTrue(d.paused);
        assertEq(d.lastPrice, _price(100));
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Closed));
        assertEq(oracle.getQuoteData(a).lastPrice, _price(100));
    }

    function test_pause_keepsPendingMove() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        _pause(a);
        assertEq(_data(a).lastPrice, _price(100));
        assertEq(_data(a).pendingPrice, _price(150));
        assertEq(oracle.getQuoteData(a).pendingPrice, _price(150));
    }

    function test_pause_roles() public {
        address[] memory as_ = new address[](1);
        as_[0] = a;
        vm.prank(ops);
        oracle.pauseAssets(as_);
        assertTrue(_data(a).paused);

        address[3] memory others = [confirmer, admin, makeAddr("rando")];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(_unauthorized(others[i], K_PRICE));
            oracle.pauseAssets(as_);
        }

        // K_TIGHTEN is not a pauser either.
        vm.prank(admin);
        impl.grantRole(K_TIGHTEN, others[2]);
        vm.prank(others[2]);
        vm.expectRevert(_unauthorized(others[2], K_PRICE));
        oracle.pauseAssets(as_);
    }

    function test_pause_isIdempotentAndRejectsUnlisted() public {
        _pause(a);
        _pause(a);
        assertTrue(_data(a).paused);
        address[] memory as_ = new address[](1);
        as_[0] = makeAddr("x");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, as_[0]));
        oracle.pauseAssets(as_);
    }

    function test_unpause_onlyOps() public {
        _pause(a);
        address[] memory as_ = new address[](1);
        as_[0] = a;
        address[3] memory others = [keeper, confirmer, admin];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(_unauthorized(others[i], MS_OPS));
            oracle.unpauseAssets(as_);
        }
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IPoppieEulerOracle.AssetUnpaused(a, ops);
        _unpause(a);
        assertFalse(_data(a).paused);
        _unpause(a); // idempotent
        as_[0] = makeAddr("x");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, as_[0]));
        oracle.unpauseAssets(as_);
    }

    function test_unpause_nextPushFollowsNormalRules() public {
        _goLive(a, _price(100));
        _pause(a);
        vm.warp(block.timestamp + 12 hours);
        _unpause(a);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Closed)); // stale
        _push(a, _price(105)); // within the bound: live again
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));

        _pause(a);
        _unpause(a);
        vm.warp(block.timestamp + 12 hours);
        _push(a, _price(200)); // beyond the bound: unconfirmed
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
        assertEq(_data(a).lastPrice, _price(105));
    }

    // -- Staleness -------------------------------------------------------------------------------

    function test_state_closesAfterMaxPriceAge() public {
        _goLive(a, _price(100));
        vm.warp(block.timestamp + 1 hours);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));
        vm.warp(block.timestamp + 1);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Closed));
        _push(a, _price(101));
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Live));
    }

    function test_state_pendingPushKeepsAssetOpenButUnconfirmed() public {
        _goLive(a, _price(100));
        vm.warp(block.timestamp + 50 minutes);
        _push(a, _price(150));
        vm.warp(block.timestamp + 50 minutes);
        // lastPriceTs is 100 min old, pendingTs 50 min old: max() is what counts.
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
        vm.warp(block.timestamp + 11 minutes);
        assertEq(uint8(_state(a)), uint8(IPoppieEulerOracle.PriceState.Closed));
    }

    // -- Risk params -----------------------------------------------------------------------------

    function test_setters_boundsAndEvents() public {
        vm.startPrank(ops);

        vm.expectRevert(IPoppieEulerOracle.InvalidParam.selector);
        oracle.setN(1);
        vm.expectRevert(IPoppieEulerOracle.InvalidParam.selector);
        oracle.setN(0);
        vm.expectRevert(IPoppieEulerOracle.InvalidParam.selector);
        oracle.setMaxPriceAge(0);
        vm.expectRevert(IPoppieEulerOracle.InvalidParam.selector);
        oracle.setMinPendingSpacing(0);
        vm.expectRevert(IPoppieEulerOracle.InvalidParam.selector);
        oracle.setClassHaircut(IPoppieEulerOracle.PriceClass.M1, 10_001);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit IPoppieEulerOracle.ParamsUpdated(2 hours, 3, 10 minutes);
        oracle.setMaxPriceAge(2 hours);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit IPoppieEulerOracle.ParamsUpdated(2 hours, 255, 10 minutes);
        oracle.setN(255);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit IPoppieEulerOracle.ParamsUpdated(2 hours, 255, 1);
        oracle.setMinPendingSpacing(1);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IPoppieEulerOracle.ClassHaircutSet(IPoppieEulerOracle.PriceClass.M2, 10_000);
        oracle.setClassHaircut(IPoppieEulerOracle.PriceClass.M2, 10_000);
        oracle.setClassHaircut(IPoppieEulerOracle.PriceClass.M3, 0);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IPoppieEulerOracle.AssetClassSet(a, IPoppieEulerOracle.PriceClass.M3);
        oracle.setAssetClass(a, IPoppieEulerOracle.PriceClass.M3);
        vm.stopPrank();

        assertEq(oracle.maxPriceAge(), 2 hours);
        assertEq(oracle.n(), 255);
        assertEq(oracle.minPendingSpacing(), 1);
        assertEq(oracle.haircutBps(IPoppieEulerOracle.PriceClass.M2), 10_000);
        assertEq(oracle.haircutBps(IPoppieEulerOracle.PriceClass.M3), 0);
        // The other classes are untouched by a class setter.
        assertEq(oracle.haircutBps(IPoppieEulerOracle.PriceClass.BlueChip), 1000);
        assertEq(oracle.haircutBps(IPoppieEulerOracle.PriceClass.M1), 1500);
        assertEq(uint8(_data(a).priceClass), uint8(IPoppieEulerOracle.PriceClass.M3));
        assertEq(oracle.getQuoteData(a).haircutBps, 0);
    }

    function test_setters_onlyOps() public {
        address[3] memory others = [keeper, confirmer, admin];
        for (uint256 i; i < others.length; ++i) {
            vm.startPrank(others[i]);
            bytes memory err = _unauthorized(others[i], MS_OPS);
            vm.expectRevert(err);
            oracle.setN(3);
            vm.expectRevert(err);
            oracle.setMaxPriceAge(1);
            vm.expectRevert(err);
            oracle.setMinPendingSpacing(1);
            vm.expectRevert(err);
            oracle.setClassHaircut(IPoppieEulerOracle.PriceClass.M1, 1);
            vm.expectRevert(err);
            oracle.setAssetClass(a, IPoppieEulerOracle.PriceClass.M1);
            vm.stopPrank();
        }
    }

    function test_setAssetClass_unlisted() public {
        address x = makeAddr("x");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, x));
        oracle.setAssetClass(x, IPoppieEulerOracle.PriceClass.M1);
    }

    function test_haircutChangeMovesTheBound() public {
        _goLive(a, _price(100));
        vm.prank(ops);
        oracle.setClassHaircut(IPoppieEulerOracle.PriceClass.BlueChip, 5000);
        _push(a, _price(150)); // now within the bound
        assertEq(_data(a).lastPrice, _price(150));
        vm.prank(ops);
        oracle.setClassHaircut(IPoppieEulerOracle.PriceClass.BlueChip, 0);
        _push(a, _price(150) + 1);
        assertEq(_data(a).lastPrice, _price(150));
        assertEq(_data(a).pendingCount, 1);
    }

    function test_spacingLongerThanMaxAge_stillPromotes() public {
        // Spacing longer than maxPriceAge is not forbidden on-chain: pending goes stale between countable pushes,
        // and the asset is Closed in between. Promotion still happens once n spaced pushes land.
        vm.startPrank(ops);
        oracle.setMinPendingSpacing(2 hours);
        vm.stopPrank();
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.warp(block.timestamp + 2 hours);
        _push(a, _price(150));
        vm.warp(block.timestamp + 2 hours);
        _push(a, _price(150));
        assertEq(_data(a).lastPrice, _price(150));
    }

    // -- Roles -----------------------------------------------------------------------------------

    function test_admin_cannotActAsOps_butCanGrant() public {
        // DEFAULT_ADMIN_ROLE manages role holders only.
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, MS_OPS));
        oracle.setN(4);
        vm.prank(admin);
        impl.grantRole(K_PRICE, makeAddr("newKeeper"));
    }

    function test_opsCanRevokeKeyRolesButNotGrant() public {
        vm.prank(ops);
        impl.revokeRole(K_PRICE, keeper);
        assertFalse(impl.hasRole(K_PRICE, keeper));
        vm.prank(ops);
        vm.expectRevert();
        impl.grantRole(K_PRICE, keeper);
    }

    // -- Batch views -----------------------------------------------------------------------------

    function test_batchViews() public {
        _goLive(a, _price(100));
        _push(address(tokenB), _price(50));
        address[] memory as_ = new address[](3);
        as_[0] = a;
        as_[1] = address(tokenB);
        as_[2] = address(tokenC);
        IPoppieEulerOracle.PriceState[] memory s = oracle.getStates(as_);
        assertEq(uint8(s[0]), uint8(IPoppieEulerOracle.PriceState.Live));
        assertEq(uint8(s[1]), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
        assertEq(uint8(s[2]), uint8(IPoppieEulerOracle.PriceState.Closed));
        IPoppieEulerOracle.QuoteData[] memory q = oracle.getQuoteDataBatch(as_);
        assertEq(q.length, 3);
        assertEq(q[0].lastPrice, _price(100));
        assertEq(q[1].pendingPrice, _price(50));
        assertEq(q[1].haircutBps, 1500);
        assertEq(q[2].decimals, 8);

        as_[2] = makeAddr("x");
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, as_[2]));
        oracle.getStates(as_);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, as_[2]));
        oracle.getQuoteDataBatch(as_);
    }

    function test_priceStateOrderingFailsClosed() public pure {
        assertEq(uint8(IPoppieEulerOracle.PriceState.Closed), 0);
        assertEq(uint8(IPoppieEulerOracle.PriceState.Unconfirmed), 1);
        assertEq(uint8(IPoppieEulerOracle.PriceState.Live), 2);
    }
}

/// @dev A second oracle with the same roles (for the format-equivalence test).
contract PoppieEulerOracleHelper is PoppieEulerOracle {
    constructor(address admin_, address keeper_, address confirmer_, address ops_) PoppieEulerOracle(admin_) {
        _grantRole(K_PRICE, keeper_);
        _grantRole(K_CONFIRM, confirmer_);
        _grantRole(MS_OPS, ops_);
    }
}
