// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgioVault {
    function balanceOf(address agent) external view returns (uint256);
    function lockedBalanceOf(address agent) external view returns (uint256);
    function debit(address agent, uint256 amount) external;
    function credit(address agent, uint256 amount) external;
    function enforceInvariant() external;

    event Deposited(address indexed agent, uint256 amount, uint256 timestamp);
    event Withdrawn(address indexed agent, uint256 amount, uint256 timestamp);
}
