// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgioVault} from "./interfaces/IAgioVault.sol";
import {IAgioRegistry} from "./interfaces/IAgioRegistry.sol";

/// @title AgioBatchSettlement — Atomic batch payment processing for AGIO
/// @notice Security: max batch value cap, per-submitter rate limiting,
///         replay protection, atomic execution.
contract AgioBatchSettlement is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    bytes32 public constant BATCH_SUBMITTER_ROLE = keccak256("BATCH_SUBMITTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct BatchPayment {
        address from;
        address to;
        uint256 amount;
        bytes32 paymentId;
    }

    struct BatchRecord {
        bytes32 batchId;
        uint64 timestamp;
        uint32 totalPayments;
        uint256 totalVolume;
        address submitter;
        BatchStatus status;
    }

    enum BatchStatus { Pending, Settled, Failed, Reverted }

    IAgioVault public vault;
    IAgioRegistry public registry;
    uint256 public maxBatchSize;
    uint256 public maxBatchValue;      // Feature: max USD value per batch

    mapping(bytes32 => BatchRecord) private _batches;
    mapping(bytes32 => bool) private _processedPayments;

    // Feature: Rate limiting per submitter
    uint256 public maxBatchesPerHour;
    mapping(address => uint256) private _submitterWindowStart;
    mapping(address => uint256) private _submitterBatchCount;

    event BatchSettled(bytes32 indexed batchId, uint256 totalPayments, uint256 totalVolume, uint256 timestamp);
    event PaymentSettled(bytes32 indexed batchId, bytes32 indexed paymentId, address indexed from, address to, uint256 amount);
    event BatchFailed(bytes32 indexed batchId, string reason);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _vault,
        address _registry,
        uint256 _maxBatchSize
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BATCH_SUBMITTER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        vault = IAgioVault(_vault);
        registry = IAgioRegistry(_registry);
        maxBatchSize = _maxBatchSize;
        maxBatchValue = 50_000e6;    // $50,000 default cap
        maxBatchesPerHour = 60;      // rate limit
    }

    /// @notice Submit a batch of payments for atomic settlement
    function submitBatch(
        BatchPayment[] calldata payments,
        bytes32 batchId
    ) external nonReentrant whenNotPaused onlyRole(BATCH_SUBMITTER_ROLE) {
        uint256 len = payments.length;
        require(len > 0, "AgioBatch: empty batch");
        require(len <= maxBatchSize, "AgioBatch: exceeds max batch size");
        require(_batches[batchId].timestamp == 0, "AgioBatch: duplicate batch ID");

        // Rate limit check
        _checkRateLimit(msg.sender);

        uint256 totalVolume;

        for (uint256 i; i < len;) {
            BatchPayment calldata p = payments[i];

            require(p.amount > 0, "AgioBatch: zero amount");
            require(p.from != p.to, "AgioBatch: self-payment");
            require(!_processedPayments[p.paymentId], "AgioBatch: duplicate payment ID");

            _processedPayments[p.paymentId] = true;
            vault.debit(p.from, p.amount);
            vault.credit(p.to, p.amount);

            totalVolume += p.amount;
            emit PaymentSettled(batchId, p.paymentId, p.from, p.to, p.amount);

            unchecked { ++i; }
        }

        // Max batch value check
        require(totalVolume <= maxBatchValue, "AgioBatch: exceeds max batch value");

        _batches[batchId] = BatchRecord({
            batchId: batchId,
            timestamp: uint64(block.timestamp),
            totalPayments: uint32(len),
            totalVolume: totalVolume,
            submitter: msg.sender,
            status: BatchStatus.Settled
        });

        if (address(registry) != address(0)) {
            _updateRegistryStats(payments);
        }

        emit BatchSettled(batchId, len, totalVolume, block.timestamp);
    }

    /// @dev Rate limit: max batches per hour per submitter
    function _checkRateLimit(address submitter) private {
        if (block.timestamp > _submitterWindowStart[submitter] + 1 hours) {
            _submitterWindowStart[submitter] = block.timestamp;
            _submitterBatchCount[submitter] = 0;
        }
        _submitterBatchCount[submitter]++;
        require(
            _submitterBatchCount[submitter] <= maxBatchesPerHour,
            "AgioBatch: rate limit exceeded"
        );
    }

    function _updateRegistryStats(BatchPayment[] calldata payments) private {
        uint256 len = payments.length;
        for (uint256 i; i < len;) {
            try registry.incrementStats(payments[i].from, 1, payments[i].amount) {} catch {}
            try registry.incrementStats(payments[i].to, 1, payments[i].amount) {} catch {}
            unchecked { ++i; }
        }
    }

    // --- View functions ---

    function getBatchStatus(bytes32 batchId) external view returns (BatchStatus) {
        return _batches[batchId].status;
    }

    function getBatchDetails(bytes32 batchId) external view returns (BatchRecord memory) {
        return _batches[batchId];
    }

    function isPaymentProcessed(bytes32 paymentId) external view returns (bool) {
        return _processedPayments[paymentId];
    }

    // --- Admin ---

    function setMaxBatchSize(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxBatchSize = newMax;
    }

    function setMaxBatchValue(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxBatchValue = newMax;
    }

    function setMaxBatchesPerHour(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxBatchesPerHour = newMax;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
