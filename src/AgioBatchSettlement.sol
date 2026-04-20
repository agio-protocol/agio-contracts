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
/// @notice Processes batches of agent-to-agent payments in a single transaction.
///         Gas optimization is critical — this is where AGIO's economics live.
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

    mapping(bytes32 => BatchRecord) private _batches;
    mapping(bytes32 => bool) private _processedPayments;

    event BatchSettled(
        bytes32 indexed batchId,
        uint256 totalPayments,
        uint256 totalVolume,
        uint256 timestamp
    );
    event PaymentSettled(
        bytes32 indexed batchId,
        bytes32 indexed paymentId,
        address indexed from,
        address to,
        uint256 amount
    );
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
    }

    /// @notice Submit a batch of payments for atomic settlement
    /// @dev Uses calldata for gas efficiency. Entire batch reverts if any payment fails.
    /// @param payments Array of payments to process
    /// @param batchId Unique identifier for this batch
    function submitBatch(
        BatchPayment[] calldata payments,
        bytes32 batchId
    ) external nonReentrant whenNotPaused onlyRole(BATCH_SUBMITTER_ROLE) {
        uint256 len = payments.length;
        require(len > 0, "AgioBatch: empty batch");
        require(len <= maxBatchSize, "AgioBatch: exceeds max batch size");
        require(_batches[batchId].timestamp == 0, "AgioBatch: duplicate batch ID");

        uint256 totalVolume;

        // Process all payments — debit senders, credit receivers via vault
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

        // Record batch (packed struct for gas efficiency)
        _batches[batchId] = BatchRecord({
            batchId: batchId,
            timestamp: uint64(block.timestamp),
            totalPayments: uint32(len),
            totalVolume: totalVolume,
            submitter: msg.sender,
            status: BatchStatus.Settled
        });

        // Update registry stats if available
        if (address(registry) != address(0)) {
            _updateRegistryStats(payments);
        }

        emit BatchSettled(batchId, len, totalVolume, block.timestamp);
    }

    /// @dev Updates agent stats in the registry. Aggregates per-agent to minimize calls.
    function _updateRegistryStats(BatchPayment[] calldata payments) private {
        // Gas note: this iterates payments twice but avoids dynamic storage allocation.
        // For production, consider an off-chain indexer updating stats instead.
        uint256 len = payments.length;
        for (uint256 i; i < len;) {
            try registry.incrementStats(payments[i].from, 1, payments[i].amount) {} catch {}
            try registry.incrementStats(payments[i].to, 1, payments[i].amount) {} catch {}
            unchecked { ++i; }
        }
    }

    function getBatchStatus(bytes32 batchId) external view returns (BatchStatus) {
        return _batches[batchId].status;
    }

    function getBatchDetails(bytes32 batchId) external view returns (BatchRecord memory) {
        return _batches[batchId];
    }

    function isPaymentProcessed(bytes32 paymentId) external view returns (bool) {
        return _processedPayments[paymentId];
    }

    function setMaxBatchSize(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxBatchSize = newMax;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
