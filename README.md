# Pledgr Smart Contracts

On-chain subscription and payment infrastructure for creator economies. Non-custodial -- funds are split at source and routed directly to recipients. No contract ever holds user funds.

Deployed on **Solana** (Anchor/Rust) and **EVM** (Solidity).

## Architecture

Both implementations share the same core design:

- **Subscriptions** -- recurring payments between subscribers and creators with configurable billing periods, trials, grace periods, auto-renewal consent, and upgrade/downgrade flows
- **Payments** -- one-time payments with split-at-source routing
- **Revenue splits** -- configurable creator/platform splits via predefined strategies (100/0 through 90/10), enforced on-chain
- **Multi-token** -- supports multiple stablecoins (USDC, USDT, etc.) with an admin-managed allowlist
- **Batch renewals** -- permissionless cranking with on-chain bounties for executors
- **Admin controls** -- pause/unpause, emergency withdraw, co-owner management with multi-wallet splits

## Structure

```
solana/           Anchor program (Rust)
  programs/pledgr/src/
    lib.rs              Program entrypoint
    state.rs            Account definitions
    errors.rs           Error codes
    instructions/       Instruction handlers

evm/              Solidity contracts
  PledgrPayments.sol        Payment processing + revenue splitting
  SubscriptionManager.sol   Subscription lifecycle management
```

## Solana

Built with [Anchor](https://www.anchor-lang.com/) v0.31.1 on Rust.

```
cd solana
anchor build
```

## EVM

Solidity ^0.8.20, uses OpenZeppelin for access control, reentrancy guards, and safe token transfers.

Compatible with Hardhat, Foundry, or any Solidity toolchain.

## Security

- Non-custodial design -- no funds are held by the contracts
- Checked arithmetic throughout (overflow protection)
- Reentrancy guards on all payment paths
- Pause mechanism with emergency withdrawal
- Co-owner key rotation without redeployment
- Audited (reports available on request)
