// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAgioVault} from "./interfaces/IAgioVault.sol";

/// @title AgioVault — Agent deposit/withdrawal vault for AGIO protocol
/// @notice Agents deposit USDC here. The batch settlement contract debits/credits balances.
contract AgioVault is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IAgioVault
{
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    IERC20 public token;
    uint256 public maxDepositCap;

    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _lockedBalances;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _token, uint256 _maxDepositCap) external initializer {
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        token = IERC20(_token);
        maxDepositCap = _maxDepositCap;
    }

    /// @notice Deposit USDC into the vault
    /// @param amount Amount in token base units (6 decimals for USDC)
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "AgioVault: zero amount");
        require(
            _balances[msg.sender] + amount <= maxDepositCap,
            "AgioVault: exceeds deposit cap"
        );

        token.safeTransferFrom(msg.sender, address(this), amount);
        _balances[msg.sender] += amount;

        emit Deposited(msg.sender, amount, block.timestamp);
    }

    /// @notice Withdraw USDC from the vault
    /// @param amount Amount to withdraw
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "AgioVault: zero amount");
        require(_balances[msg.sender] >= amount, "AgioVault: insufficient balance");

        _balances[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, block.timestamp);
    }

    /// @notice Returns agent's available (unlocked) balance
    function balanceOf(address agent) external view returns (uint256) {
        return _balances[agent];
    }

    /// @notice Returns agent's locked balance (in pending batches)
    function lockedBalanceOf(address agent) external view returns (uint256) {
        return _lockedBalances[agent];
    }

    /// @notice Debit an agent's balance (called by batch settlement contract)
    /// @param agent The agent to debit
    /// @param amount The amount to debit
    function debit(address agent, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        require(_balances[agent] >= amount, "AgioVault: insufficient balance for debit");
        _balances[agent] -= amount;
    }

    /// @notice Credit an agent's balance (called by batch settlement contract)
    /// @param agent The agent to credit
    /// @param amount The amount to credit
    function credit(address agent, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        _balances[agent] += amount;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setMaxDepositCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxDepositCap = newCap;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
