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
/// @notice Agents deposit USDC here. Batch settlement debits/credits balances.
/// @dev Security features: CEI pattern, circuit breaker, tiered withdrawal delays,
///      multi-sig ready access control. See SECURITY.md for role assignment guide.
contract AgioVault is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IAgioVault
{
    using SafeERC20 for IERC20;

    // --- Roles ---
    // MULTISIG GUIDE: Before mainnet, transfer these to Gnosis Safe:
    //   DEFAULT_ADMIN_ROLE → 3-of-5 multisig (team founders)
    //   UPGRADER_ROLE      → 4-of-5 multisig (highest security)
    //   PAUSER_ROLE        → 2-of-3 multisig (ops team, fast response)
    //   SETTLEMENT_ROLE    → batch settlement contract address (not a human)
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    IERC20 public token;
    uint256 public maxDepositCap;

    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _lockedBalances;

    // --- Feature: Tiered Withdrawal Delays ---
    uint256 public instantWithdrawLimit;     // below this: instant (default $1,000)
    uint256 public mediumWithdrawLimit;       // below this: 1hr delay (default $10,000)
    uint256 public mediumWithdrawDelay;       // 1 hour
    uint256 public largeWithdrawDelay;        // 24 hours

    struct PendingWithdrawal {
        uint256 amount;
        uint64 requestedAt;
        uint64 availableAt;
    }
    mapping(address => PendingWithdrawal) public pendingWithdrawals;

    event WithdrawalRequested(address indexed agent, uint256 amount, uint256 availableAt);
    event WithdrawalCancelled(address indexed agent, uint256 amount);

    // --- Feature: Circuit Breaker ---
    uint256 public circuitBreakerThresholdBps; // basis points (default 2000 = 20%)
    uint256 public circuitBreakerWindow;       // seconds (default 1 hour)
    uint256 private _windowStart;
    uint256 private _windowOutflows;

    event CircuitBreakerTriggered(uint256 outflows, uint256 threshold, uint256 window);

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

        // Withdrawal delay defaults (in USDC base units, 6 decimals)
        instantWithdrawLimit = 1_000e6;    // $1,000
        mediumWithdrawLimit = 10_000e6;    // $10,000
        mediumWithdrawDelay = 1 hours;
        largeWithdrawDelay = 24 hours;

        // Circuit breaker defaults
        circuitBreakerThresholdBps = 2000; // 20%
        circuitBreakerWindow = 1 hours;
    }

    /// @notice Deposit USDC into the vault
    /// @dev CEI PATTERN: checks → state update → external call
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "AgioVault: zero amount");
        require(
            _balances[msg.sender] + amount <= maxDepositCap,
            "AgioVault: exceeds deposit cap"
        );

        // EFFECTS before INTERACTIONS (CEI pattern — audit fix)
        _balances[msg.sender] += amount;

        // INTERACTION last
        token.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount, block.timestamp);
    }

    /// @notice Withdraw USDC — instant for small amounts, delayed for large
    /// @param amount Amount to withdraw
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "AgioVault: zero amount");
        require(_balances[msg.sender] >= amount, "AgioVault: insufficient balance");

        if (amount <= instantWithdrawLimit) {
            // Instant withdrawal for small amounts
            _executeWithdraw(msg.sender, amount);
        } else {
            // Queue delayed withdrawal
            uint256 delay = amount <= mediumWithdrawLimit ? mediumWithdrawDelay : largeWithdrawDelay;
            _balances[msg.sender] -= amount;
            _lockedBalances[msg.sender] += amount;

            pendingWithdrawals[msg.sender] = PendingWithdrawal({
                amount: amount,
                requestedAt: uint64(block.timestamp),
                availableAt: uint64(block.timestamp + delay)
            });

            emit WithdrawalRequested(msg.sender, amount, block.timestamp + delay);
        }
    }

    /// @notice Execute a previously queued delayed withdrawal
    function executeDelayedWithdrawal() external nonReentrant whenNotPaused {
        PendingWithdrawal memory pw = pendingWithdrawals[msg.sender];
        require(pw.amount > 0, "AgioVault: no pending withdrawal");
        require(block.timestamp >= pw.availableAt, "AgioVault: withdrawal not yet available");

        uint256 amount = pw.amount;
        delete pendingWithdrawals[msg.sender];
        _lockedBalances[msg.sender] -= amount;

        // Circuit breaker check
        _checkCircuitBreaker(amount);

        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, block.timestamp);
    }

    /// @notice Cancel a pending delayed withdrawal
    function cancelDelayedWithdrawal() external {
        PendingWithdrawal memory pw = pendingWithdrawals[msg.sender];
        require(pw.amount > 0, "AgioVault: no pending withdrawal");

        uint256 amount = pw.amount;
        delete pendingWithdrawals[msg.sender];
        _lockedBalances[msg.sender] -= amount;
        _balances[msg.sender] += amount;

        emit WithdrawalCancelled(msg.sender, amount);
    }

    function _executeWithdraw(address agent, uint256 amount) private {
        // Circuit breaker check
        _checkCircuitBreaker(amount);

        // CEI: state before transfer
        _balances[agent] -= amount;
        token.safeTransfer(agent, amount);

        emit Withdrawn(agent, amount, block.timestamp);
    }

    /// @dev Circuit breaker: auto-pauses if outflows exceed threshold in window
    function _checkCircuitBreaker(uint256 outflow) private {
        if (block.timestamp > _windowStart + circuitBreakerWindow) {
            _windowStart = block.timestamp;
            _windowOutflows = 0;
        }

        _windowOutflows += outflow;
        uint256 totalBalance = token.balanceOf(address(this));
        uint256 threshold = (totalBalance + _windowOutflows) * circuitBreakerThresholdBps / 10000;

        if (_windowOutflows > threshold) {
            _pause();
            emit CircuitBreakerTriggered(_windowOutflows, threshold, circuitBreakerWindow);
        }
    }

    // --- Balance queries ---

    function balanceOf(address agent) external view returns (uint256) {
        return _balances[agent];
    }

    function lockedBalanceOf(address agent) external view returns (uint256) {
        return _lockedBalances[agent];
    }

    // --- Settlement interface (called by batch contract) ---

    function debit(address agent, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        require(_balances[agent] >= amount, "AgioVault: insufficient balance for debit");
        _balances[agent] -= amount;
    }

    function credit(address agent, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        _balances[agent] += amount;
    }

    // --- Admin functions ---

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setMaxDepositCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxDepositCap = newCap;
    }

    function setWithdrawLimits(
        uint256 _instant,
        uint256 _medium,
        uint256 _mediumDelay,
        uint256 _largeDelay
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        instantWithdrawLimit = _instant;
        mediumWithdrawLimit = _medium;
        mediumWithdrawDelay = _mediumDelay;
        largeWithdrawDelay = _largeDelay;
    }

    function setCircuitBreaker(
        uint256 _thresholdBps,
        uint256 _window
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        circuitBreakerThresholdBps = _thresholdBps;
        circuitBreakerWindow = _window;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
