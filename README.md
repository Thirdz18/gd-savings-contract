# GoodDollar (G$) Savings Smart Contract

A community-built savings contract for **GoodDollar (G$)** tokens deployed on the **Celo Mainnet**.

## Overview

This contract allows users to lock G$ tokens for a fixed duration and earn a savings reward upon withdrawal. It is integrated into the **GoodMarket** platform — a community DApp built on top of the GoodDollar protocol.

## Deployed Contract

| Property | Value |
|---|---|
| **Network** | Celo Mainnet |
| **Contract Address** | `0xD549CEE2691d6Da8246B4c56CcdfCf7318962032` |
| **CeloScan** | [View on CeloScan](https://celoscan.io/address/0xD549CEE2691d6Da8246B4c56CcdfCf7318962032#code) |
| **Compiler** | Solidity `v0.8.21` |
| **G$ Token (Celo)** | `0x62B8B11039FcfE5aB0C56E502b1C372A3d2a9c7A` |

## Features

- **Time-locked savings** — Users deposit G$ tokens and lock them for a set period
- **Reward on withdrawal** — Rewards are paid from a reward pool funded by the platform
- **Multiple deposits** — Each user can have multiple active deposits simultaneously
- **Emergency pause** — Owner can pause/unpause the contract in case of emergency
- **Reentrancy protection** — All state-changing functions are protected against reentrancy attacks
- **Safe ERC20 handling** — Uses SafeERC20 pattern for all token transfers

## Contract Architecture

```
GDSavings
├── IERC20              — Standard ERC20 interface
├── SafeERC20           — Safe token transfer library
├── Address             — Address utility library
├── Ownable             — Access control (owner-only functions)
├── ReentrancyGuard     — Protection against reentrancy attacks
└── Pausable            — Emergency pause capability
```

## Key Functions

| Function | Who | Description |
|---|---|---|
| `deposit(amount, lockDays)` | User | Deposit G$ and lock for N days |
| `withdraw(depositId)` | User | Withdraw after lock period + receive reward |
| `fundRewardPool(amount)` | Owner | Add G$ to the reward pool |
| `withdrawRewardPool(amount)` | Owner | Remove G$ from reward pool |
| `pause()` / `unpause()` | Owner | Emergency pause/unpause |
| `getUserDeposits(wallet)` | Anyone | View all deposits for a wallet |
| `getDepositInfo(depositId)` | Anyone | View details of a specific deposit |

## How It Works

1. User approves the contract to spend their G$ tokens
2. User calls `deposit(amount, lockDays)` — tokens are transferred to the contract
3. After the lock period expires, user calls `withdraw(depositId)`
4. Contract returns the original deposit + reward from the reward pool

## Security

- `ReentrancyGuard` on all deposit/withdraw functions
- `Pausable` for emergency stops
- `Ownable` restricts admin functions to the contract owner
- `SafeERC20` for safe token transfers

## License

MIT
