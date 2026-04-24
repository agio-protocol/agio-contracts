# AGIO Protocol — Smart Contracts

Non-custodial smart contracts for AI agent micropayment settlement on Base (EVM) and Solana.

## Why This Is Public

AI agents need to trust the code holding their money. This source code is published so any agent or operator can independently audit the smart contracts before depositing funds.

Every contract deployed on-chain is verified and matches this source code exactly.

## Architecture

### Base Mainnet (Solidity / Foundry)

| Contract | Address | Purpose |
|----------|---------|---------|
| **AgioVault** | `0xe68bA48B4178a83212c00d6cb28c5A93Ec3FeEBc` | Multi-token vault with per-agent balances, circuit breaker, tiered withdrawals |
| **AgioBatchSettlement** | `0x3937a057AE18971657AD12830964511B73D9e7C5` | Batch payment settlement with ECDSA signature verification |
| **AgioRegistry** | `0xEfC4166Fc14758bAE879Bf439848Cb26E8f74927` | Agent identity, reputation tiers, auto-upgrade |
| **AgioSwapRouter** | `0x3428833a0E578Fb0BF9bE6Db45F36B99476949d8` | Cross-token settlement with preferred token routing |

All contracts use OpenZeppelin v5 UUPS upgradeable proxy pattern.

Verify on Basescan: [AgioVault](https://basescan.org/address/0xe68bA48B4178a83212c00d6cb28c5A93Ec3FeEBc#code)

### Solana Mainnet (Anchor / Rust)

| Program | Address | Purpose |
|---------|---------|---------|
| **AGIO Vault** | `68RkssMLwfAWZ3Hf8TGF6poACgvo7ePPA8BzThqoMp6y` | PDA vault with agent accounts, batch settlement, Ed25519 signatures |

Vault PDA: `3wtiPBWPNAy5QeJkSUEdgNcazMukTmxZSVYS3Mk8EkxQ`

Verify on Solscan: [Program](https://solscan.io/account/68RkssMLwfAWZ3Hf8TGF6poACgvo7ePPA8BzThqoMp6y)

## Directory Structure

```
src/                    # Solidity contracts (Base / EVM)
  AgioVault.sol         # Multi-token vault
  AgioBatchSettlement.sol # Batch settlement
  AgioRegistry.sol      # Agent identity
  AgioSwapRouter.sol    # Cross-token routing
  interfaces/           # Contract interfaces

solana-vault/           # Anchor program (Solana)
  src/
    lib.rs              # Program entry point
    state.rs            # Account structures
    instructions/       # Instruction handlers
```

## Security

- All contracts auditable on-chain via Basescan/Solscan
- UUPS proxy pattern with owner-only upgrades
- Circuit breaker for emergency pause
- Per-token invariant checks
- Tiered withdrawal limits based on agent reputation
- Ed25519 signature verification (Solana)
- ECDSA batch verification (Base)

## License

BUSL-1.1. See [IP_NOTICE.md](IP_NOTICE.md).

You may view and audit this code. You may NOT deploy or use it commercially without a license from AGIO Protocol.

## Links

- Platform: [agiotage.finance](https://agiotage.finance)
- API Discovery: [agiotage.finance/.well-known/agio.json](https://agiotage.finance/.well-known/agio.json)
