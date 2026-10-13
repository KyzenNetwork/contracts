// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {SiliconMainnetTerms as Terms} from "../../script/SiliconMainnet.sol";
import {RecordSiliconMainnet} from "../../script/RecordSiliconMainnet.s.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";
import {SiliconMainnetFork} from "./utils/SiliconMainnetFork.sol";

/// The Silicon recorder (script/RecordSiliconMainnet.s.sol) against a deployment of SiliconMainnet
/// made on a fork of Robinhood Chain mainnet from the owner wallet. It writes a scratch copy of
/// deployments/4663.json (deleted afterwards), never the file itself. Skipped unless
/// ROBINHOOD_RPC_URL is set.
contract RecordSiliconMainnetForkTest is SiliconMainnetFork {
    /// Scratch copies of deployments/4663.json, one per test (forge runs the tests in parallel).
    string internal constant SCRATCH_WRITE = "deployments/.silicon-record-write-4663.json";
    string internal constant SCRATCH_RUN = "deployments/.silicon-record-run-4663.json";

    RecordSiliconMainnet internal recorder;

    function setUp() public {
        _fork();
        recorder = new RecordSiliconMainnet();
    }

    function test_reads_every_address_from_the_deployment() public {
        _deploy();
        RecordSiliconMainnet.Record memory r = recorder.read(address(deployment));
        _assertRecord(r);

        // The same once the owner has accepted everything.
        _acceptAll();
        _assertRecord(recorder.read(address(deployment)));
    }

    function test_writes_the_silicon_object_and_leaves_the_rest_of_the_file() public {
        _deploy();
        RecordSiliconMainnet.Record memory r = recorder.read(address(deployment));
        vm.copyFile("deployments/4663.json", SCRATCH_WRITE);
        string memory before = vm.readFile(SCRATCH_WRITE);
        recorder.write(r, SCRATCH_WRITE);
        string memory json = vm.readFile(SCRATCH_WRITE);
        vm.removeFile(SCRATCH_WRITE);

        // The keys the testnet deployment records, and deployBlock.
        string memory testnet = vm.readFile("deployments/46630.json");
        string[] memory keys = vm.parseJsonKeys(json, ".silicon");
        string[] memory testnetKeys = vm.parseJsonKeys(testnet, ".silicon");
        for (uint256 i; i < testnetKeys.length; ++i) {
            assertTrue(vm.keyExistsJson(json, string.concat(".silicon.", testnetKeys[i])), testnetKeys[i]);
        }
        for (uint256 i; i < keys.length; ++i) {
            bool mainnetOnly = keccak256(bytes(keys[i])) == keccak256("deployBlock")
                || keccak256(bytes(keys[i])) == keccak256("swapAdapter");
            assertTrue(mainnetOnly || vm.keyExistsJson(testnet, string.concat(".silicon.", keys[i])), keys[i]);
        }
        assertTrue(vm.keyExistsJson(json, ".silicon.deployBlock"));
        assertEq(vm.parseJsonAddress(json, ".silicon.swapAdapter"), address(swapAdapter));
        assertEq(vm.parseJsonKeys(json, ".silicon.markets[0]"), vm.parseJsonKeys(testnet, ".silicon.markets[0]"));
        assertEq(vm.parseJsonKeys(json, ".silicon.stockFeeds"), vm.parseJsonKeys(testnet, ".silicon.stockFeeds"));

        assertEq(vm.parseJsonUint(json, ".silicon.deployBlock"), deployment.deployBlock());
        assertEq(vm.parseJsonAddress(json, ".silicon.vault"), address(vault));
        assertEq(vm.parseJsonAddress(json, ".silicon.oracle"), address(oracle));
        assertEq(vm.parseJsonAddress(json, ".silicon.calendar"), address(calendar));
        assertEq(vm.parseJsonAddress(json, ".silicon.feeRouter"), address(feeRouter));
        assertEq(vm.parseJsonAddress(json, ".silicon.usdg"), Terms.USDG);
        assertEq(vm.parseJsonUint(json, ".silicon.oracleShortWindow"), 1 hours);
        assertEq(vm.parseJsonUint(json, ".silicon.oracleLongWindow"), 24 hours);
        assertEq(vm.parseJsonUint(json, ".silicon.auctionDuration"), 100 minutes);
        assertEq(vm.parseJsonAddress(json, ".silicon.stockFeeds.NVDA"), RH.NVDA_USD);
        assertEq(vm.parseJsonAddress(json, ".silicon.stockFeeds.AMD"), RH.AMD_USD);
        assertEq(vm.parseJsonAddress(json, ".silicon.stockFeeds.MU"), RH.MU_USD);
        assertEq(vm.parseJsonAddress(json, ".silicon.stockFeeds.SNDK"), RH.SNDK_USD);
        assertEq(vm.parseJsonAddress(json, ".silicon.stockFeeds.TSM"), RH.TSM_USD);
        assertEq(vm.parseJsonAddress(json, ".silicon.stockFeeds.INTC"), RH.INTC_USD);
        assertEq(vm.parseJsonAddress(json, ".silicon.stockFeeds.ASML"), RH.ASML_USD);
        for (uint256 id; id < MARKETS; ++id) {
            string memory m = string.concat(".silicon.markets[", vm.toString(id), "]");
            SiliconVault.Market memory market = vault.market(id);
            assertEq(vm.parseJsonString(json, string.concat(m, ".name")), Terms.index(id).name);
            assertEq(vm.parseJsonString(json, string.concat(m, ".symbol")), Terms.index(id).symbol);
            assertEq(vm.parseJsonAddress(json, string.concat(m, ".synth")), address(synths[id]));
            assertEq(vm.parseJsonAddress(json, string.concat(m, ".feed")), address(feeds[id]));
            // Decimal strings: past JavaScript's safe integers.
            assertEq(vm.parseJsonString(json, string.concat(m, ".debtCeiling")), vm.toString(market.debtCeiling));
            assertEq(vm.parseJsonString(json, string.concat(m, ".minDebt")), vm.toString(market.minDebt));
        }

        // Every other key is as it was.
        string[] memory topKeys = vm.parseJsonKeys(before, "$");
        for (uint256 i; i < topKeys.length; ++i) {
            if (keccak256(bytes(topKeys[i])) == keccak256("silicon")) continue;
            string memory path = string.concat(".", topKeys[i]);
            assertEq(vm.parseJson(json, path), vm.parseJson(before, path), topKeys[i]);
        }
        assertEq(vm.parseJsonKeys(json, "$").length, topKeys.length + (vm.keyExistsJson(before, ".silicon") ? 0 : 1));
    }

    function test_run_records_from_the_environment_and_checks_the_receipt_block() public {
        _deploy();
        vm.copyFile("deployments/4663.json", SCRATCH_RUN);
        vm.setEnv("KYZEN_SILICON", vm.toString(address(deployment)));
        vm.setEnv("KYZEN_DEPLOYMENT_FILE", SCRATCH_RUN);

        // A receipt block that is not the deployment's: nothing is written.
        vm.setEnv("KYZEN_SILICON_BLOCK", vm.toString(block.number + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                RecordSiliconMainnet.ValueMismatch.selector, "deployBlock", block.number + 1, block.number
            )
        );
        recorder.run();
        assertFalse(vm.keyExistsJson(vm.readFile(SCRATCH_RUN), ".silicon.deployBlock"));

        vm.setEnv("KYZEN_SILICON_BLOCK", vm.toString(block.number));
        recorder.run();
        string memory json = vm.readFile(SCRATCH_RUN);
        vm.removeFile(SCRATCH_RUN);
        assertEq(vm.parseJsonUint(json, ".silicon.deployBlock"), block.number);
        assertEq(vm.parseJsonAddress(json, ".silicon.vault"), address(vault));

        // Off mainnet it records nothing.
        vm.chainId(46630);
        vm.expectRevert(abi.encodeWithSelector(RecordSiliconMainnet.NotMainnet.selector, 46630));
        recorder.run();
    }

    function test_refuses_what_is_not_the_owners_deployment() public {
        address nothing = makeAddr("nothing");
        vm.expectRevert(abi.encodeWithSelector(RecordSiliconMainnet.NoCode.selector, "SiliconMainnet", nothing));
        recorder.read(nothing);

        // A vault whose guardian the owner has moved is not the deployment as made.
        _deploy();
        _acceptAll();
        address other = makeAddr("other");
        vm.prank(OWNER);
        vault.setGuardian(other);
        vm.expectRevert(abi.encodeWithSelector(RecordSiliconMainnet.Mismatch.selector, "vault.guardian", OWNER, other));
        recorder.read(address(deployment));
    }

    function _assertRecord(RecordSiliconMainnet.Record memory r) internal view {
        assertEq(r.deployment, address(deployment));
        assertEq(r.deployBlock, deployment.deployBlock());
        assertEq(r.deployBlock, block.number);
        assertEq(r.owner, OWNER);
        assertEq(r.calendar, address(calendar));
        assertEq(r.oracle, address(oracle));
        assertEq(r.vault, address(vault));
        assertEq(r.feeRouter, address(feeRouter));
        assertEq(r.swapAdapter, address(swapAdapter));
        assertEq(r.usdg, Terms.USDG);
        assertEq(r.oracleShortWindow, 1 hours);
        assertEq(r.oracleLongWindow, 24 hours);
        assertEq(r.auctionDuration, 100 minutes);
        for (uint256 id; id < MARKETS; ++id) {
            assertEq(r.markets[id].name, Terms.index(id).name);
            assertEq(r.markets[id].symbol, Terms.index(id).symbol);
            assertEq(r.markets[id].synth, address(synths[id]));
            assertEq(r.markets[id].feed, address(feeds[id]));
            assertEq(r.markets[id].debtCeiling, vault.market(id).debtCeiling);
            assertEq(r.markets[id].minDebt, vault.market(id).minDebt);
        }
    }
}
