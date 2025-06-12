# IDXFlowOrderFlow

## 📌 Overview


A modular Ethereum smart contract that rewards high-frequency traders and stakers through a composable, multi-tiered incentive system. It tracks per-user trading volume across epochs, distributes token rewards with vesting and auto-compounding options, and supports advanced features such as permit-based staking, gas rebates, NFT-bound accounts (ERC-6551), zero-knowledge proof validation, KYC compliance, and cross-chain state mirroring using LayerZero. The protocol is designed for scalable, compliant, and capital-efficient DeFi reward distribution.

This repository contains an Ethereum adaptation of the Solana-based **IDXFlow OrderFlow** smart contract(https://github.com/btorressz/idxflow_orderflow)

- ✅ A full-featured Solidity smart contract: `IDXFlowOrderFlow.sol`  
- 🧪 A lightweight mock contract for testing: `MockIDXFlow.sol`  
- 🧾 A JavaScript test file for Remix testing: `tests.js`

---

## ⚙️ Features

- **Epoch-Based Rewards**  
  Tracks per-user trading volume and issues ERC-20 token rewards per epoch.

- **Staking + Tier System**  
  Users stake tokens to upgrade their fee tier (Bronze → Diamond), unlocking higher multipliers.

- **Meta-Transactions & Permits**  
  Supports EIP-712 signature-based reward claims and ERC-2612 permits for gasless staking.

- **Auto-Compounding & Vesting**  
  Splits rewards into immediate (25%) and vested (75%) portions, with optional auto-staking.

- **Gas Rebates**  
  Rebates gas costs in reward tokens if gas usage is under a threshold.

- **ERC-1363 Auto-Stake Support**  
  Automatically stakes tokens received via `transferAndCall`.

- **ERC-6551 NFT-Bound Accounts**  
  Binds a user's staking account to an NFT using ERC-6551.

- **ZK Proofs and KYC Compliance**  
  Supports privacy-preserving claims and regulatory checks.

- **Merkle Drop Rewards**  
  Efficient batch reward distribution using Merkle trees.

- **LayerZero Cross-Chain Sync**  
  Allows syncing of key state across chains using LayerZero.

---
