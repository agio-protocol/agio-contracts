// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgioVault} from "../src/AgioVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract AgioVaultTest is Test {
    AgioVault public vault;
    MockUSDC public usdc;
    address public admin = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 constant MAX_CAP = 10_000e6; // $10,000 in USDC base units

    function setUp() public {
        usdc = new MockUSDC();

        AgioVault impl = new AgioVault();
        bytes memory initData = abi.encodeCall(impl.initialize, (address(usdc), MAX_CAP));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = AgioVault(address(proxy));

        // Fund test accounts
        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);

        // Approve vault
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_deposit() public {
        vm.prank(alice);
        vault.deposit(100e6);

        assertEq(vault.balanceOf(alice), 100e6);
        assertEq(usdc.balanceOf(alice), 900e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
    }

    function test_withdraw() public {
        vm.prank(alice);
        vault.deposit(100e6);

        vm.prank(alice);
        vault.withdraw(50e6);

        assertEq(vault.balanceOf(alice), 50e6);
        assertEq(usdc.balanceOf(alice), 950e6);
    }

    function test_withdraw_insufficient_balance() public {
        vm.prank(alice);
        vault.deposit(100e6);

        vm.prank(alice);
        vm.expectRevert("AgioVault: insufficient balance");
        vault.withdraw(200e6);
    }

    function test_deposit_exceeds_cap() public {
        usdc.mint(alice, MAX_CAP);

        vm.prank(alice);
        vault.deposit(MAX_CAP);

        vm.prank(alice);
        vm.expectRevert("AgioVault: exceeds deposit cap");
        vault.deposit(1);
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert("AgioVault: zero amount");
        vault.deposit(0);
    }

    function test_pause_blocks_deposits() public {
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(100e6);
    }

    function test_pause_blocks_withdrawals() public {
        vm.prank(alice);
        vault.deposit(100e6);

        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(50e6);
    }

    function test_debit_credit_by_settlement_role() public {
        vm.prank(alice);
        vault.deposit(100e6);

        // Grant settlement role to this contract
        vault.grantRole(vault.SETTLEMENT_ROLE(), address(this));

        vault.debit(alice, 30e6);
        assertEq(vault.balanceOf(alice), 70e6);

        vault.credit(bob, 30e6);
        assertEq(vault.balanceOf(bob), 30e6);
    }

    function test_debit_unauthorized_reverts() public {
        vm.prank(alice);
        vault.deposit(100e6);

        vm.prank(bob);
        vm.expectRevert();
        vault.debit(alice, 30e6);
    }

    event Deposited(address indexed agent, uint256 amount, uint256 timestamp);

    function test_events() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, 100e6, block.timestamp);
        vault.deposit(100e6);
    }
}
