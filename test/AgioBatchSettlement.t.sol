// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgioVault} from "../src/AgioVault.sol";
import {AgioBatchSettlement} from "../src/AgioBatchSettlement.sol";
import {AgioRegistry} from "../src/AgioRegistry.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract AgioBatchSettlementTest is Test {
    AgioVault public vault;
    AgioBatchSettlement public batch;
    AgioRegistry public registry;
    MockUSDC public usdc;

    address public admin = address(this);
    uint256 constant MAX_CAP = 100_000e6;

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy vault
        AgioVault vaultImpl = new AgioVault();
        vault = AgioVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(vaultImpl.initialize, (address(usdc), MAX_CAP))
        )));

        // Deploy registry
        AgioRegistry regImpl = new AgioRegistry();
        registry = AgioRegistry(address(new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(regImpl.initialize, ())
        )));

        // Deploy batch settlement
        AgioBatchSettlement batchImpl = new AgioBatchSettlement();
        batch = AgioBatchSettlement(address(new ERC1967Proxy(
            address(batchImpl),
            abi.encodeCall(batchImpl.initialize, (address(vault), address(registry), 500))
        )));

        // Grant roles
        vault.grantRole(vault.SETTLEMENT_ROLE(), address(batch));
        registry.grantRole(registry.BATCH_SETTLEMENT_ROLE(), address(batch));
    }

    function _fundAgent(address agent, uint256 amount) internal {
        usdc.mint(agent, amount);
        vm.startPrank(agent);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _makePayment(address from, address to, uint256 amount, bytes32 pid)
        internal pure returns (AgioBatchSettlement.BatchPayment memory)
    {
        return AgioBatchSettlement.BatchPayment(from, to, amount, pid);
    }

    function test_single_payment_batch() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        _fundAgent(alice, 100e6);

        AgioBatchSettlement.BatchPayment[] memory payments = new AgioBatchSettlement.BatchPayment[](1);
        payments[0] = _makePayment(alice, bob, 10e6, keccak256("pay1"));

        batch.submitBatch(payments, keccak256("batch1"));

        assertEq(vault.balanceOf(alice), 90e6);
        assertEq(vault.balanceOf(bob), 10e6);

        AgioBatchSettlement.BatchRecord memory record = batch.getBatchDetails(keccak256("batch1"));
        assertEq(record.totalPayments, 1);
        assertEq(record.totalVolume, 10e6);
        assertTrue(record.status == AgioBatchSettlement.BatchStatus.Settled);
    }

    function test_100_payment_batch() public {
        uint256 numPayments = 100;
        address[] memory agents = new address[](numPayments + 1);

        // Create funded agents
        for (uint256 i; i < numPayments + 1; i++) {
            agents[i] = address(uint160(0x1000 + i));
            _fundAgent(agents[i], 1000e6);
        }

        // Build batch: agent[i] pays agent[i+1]
        AgioBatchSettlement.BatchPayment[] memory payments = new AgioBatchSettlement.BatchPayment[](numPayments);
        for (uint256 i; i < numPayments; i++) {
            payments[i] = _makePayment(
                agents[i], agents[i + 1], 1e6,
                keccak256(abi.encodePacked("pay", i))
            );
        }

        batch.submitBatch(payments, keccak256("batch100"));

        AgioBatchSettlement.BatchRecord memory record = batch.getBatchDetails(keccak256("batch100"));
        assertEq(record.totalPayments, 100);
    }

    function test_batch_with_insufficient_balance_reverts() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        _fundAgent(alice, 10e6);

        AgioBatchSettlement.BatchPayment[] memory payments = new AgioBatchSettlement.BatchPayment[](1);
        payments[0] = _makePayment(alice, bob, 100e6, keccak256("pay1"));

        vm.expectRevert("AgioVault: insufficient balance for debit");
        batch.submitBatch(payments, keccak256("batch_fail"));
    }

    function test_duplicate_paymentId_reverts() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        _fundAgent(alice, 100e6);

        AgioBatchSettlement.BatchPayment[] memory payments = new AgioBatchSettlement.BatchPayment[](1);
        payments[0] = _makePayment(alice, bob, 10e6, keccak256("pay1"));

        batch.submitBatch(payments, keccak256("batch1"));

        // Try submitting same paymentId again
        payments[0] = _makePayment(alice, bob, 10e6, keccak256("pay1"));
        vm.expectRevert("AgioBatch: duplicate payment ID");
        batch.submitBatch(payments, keccak256("batch2"));
    }

    function test_unauthorized_submitter_reverts() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address mallory = address(0xBAD);
        _fundAgent(alice, 100e6);

        AgioBatchSettlement.BatchPayment[] memory payments = new AgioBatchSettlement.BatchPayment[](1);
        payments[0] = _makePayment(alice, bob, 10e6, keccak256("pay1"));

        vm.prank(mallory);
        vm.expectRevert();
        batch.submitBatch(payments, keccak256("batch1"));
    }

    function test_empty_batch_reverts() public {
        AgioBatchSettlement.BatchPayment[] memory payments = new AgioBatchSettlement.BatchPayment[](0);
        vm.expectRevert("AgioBatch: empty batch");
        batch.submitBatch(payments, keccak256("batch_empty"));
    }

    function test_self_payment_reverts() public {
        address alice = address(0xA11CE);
        _fundAgent(alice, 100e6);

        AgioBatchSettlement.BatchPayment[] memory payments = new AgioBatchSettlement.BatchPayment[](1);
        payments[0] = _makePayment(alice, alice, 10e6, keccak256("pay1"));

        vm.expectRevert("AgioBatch: self-payment");
        batch.submitBatch(payments, keccak256("batch1"));
    }

    function test_gas_usage_100_payments() public {
        uint256 numPayments = 100;
        address[] memory agents = new address[](numPayments + 1);

        for (uint256 i; i < numPayments + 1; i++) {
            agents[i] = address(uint160(0x1000 + i));
            _fundAgent(agents[i], 1000e6);
        }

        AgioBatchSettlement.BatchPayment[] memory payments = new AgioBatchSettlement.BatchPayment[](numPayments);
        for (uint256 i; i < numPayments; i++) {
            payments[i] = _makePayment(
                agents[i], agents[i + 1], 1e6,
                keccak256(abi.encodePacked("gas", i))
            );
        }

        uint256 gasBefore = gasleft();
        batch.submitBatch(payments, keccak256("gas_batch_100"));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for 100 payments:", gasUsed);
        // With registry updates: ~3.9M gas. Without: ~1.5M.
        // Production optimization: move registry updates to off-chain indexer.
        assertLt(gasUsed, 5_000_000, "Gas too high for 100-payment batch");
    }
}
