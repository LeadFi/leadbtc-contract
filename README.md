LeadBTC Custody & Token Contracts






📖 Overview

This repository contains the smart contracts powering LeadBTC, a wrapped Bitcoin token and its associated custody & fee management system.

The system ensures BTC-backed token minting, secure withdrawals, fee enforcement, blacklist control, and LayerZero cross-chain operability.

Main components:

CustodyManager – Manages BTC deposits, escrows withdrawals, and finalizes burns after off-chain settlement.

LeadBTC (OFT) – LayerZero-enabled wrapped Bitcoin token (ERC20-compatible with 8 decimals).

FixedFeePolicy – Simple fee policy for deposit and withdrawal operations.

✨ Features

✅ BTC-backed minting via verified deposits.

✅ Withdrawal workflow: escrow → lock → finalize burn → PoR reconciliation.

✅ Proof-of-Reserve (PoR) integration hooks.

✅ Flexible fee policies (deposit + withdraw).

✅ Blacklist support at the token level.

✅ Cross-chain OFT (LayerZero) support.

✅ Role-based access control (admin, operator, depositor, withdrawer).

✅ Pausable & secure (ReentrancyGuard).

📦 Contracts
1. CustodyManager.sol

Responsible for:

Confirming deposits and minting LeadBTC.

Escrowing withdrawals (no burn yet).

Finalizing withdrawals by burning the full escrow amount.

Managing custody BTC addresses (valid sources for deposits).

Optional mintHook for PoR or compliance integration.

Roles:

ADMIN_ROLE – Governance, manages policies and params.

OP_ROLE – Can manage custody BTC addresses.

DEPOSIT_ROLE – Confirms deposits and mints tokens.

WITHDRAW_ROLE – Locks and finalizes withdrawals.

2. LeadBTC.sol

An OFT (Omnichain Fungible Token) with LayerZero cross-chain support.

Features:

8 decimals (BTC satoshi precision).

Minter-controlled mint & burn.

Blacklist mechanism (restricted accounts cannot send/receive).

3. FixedFeePolicy.sol

Implements IFeePolicy interface.

Fixed mintFee per deposit.

Fixed withdrawFee per withdrawal.

Fees are denominated in token units (satoshis if decimals=8).

⚡ Deployment
Prerequisites

Node.js ≥ 18

Hardhat

Access to LayerZero endpoint configs

Compile
npx hardhat compile

Deploy Example (BSC Testnet)
npx hardhat run scripts/deploy.js --network bscTestnet

Verify Contract
npx hardhat verify --network bscTestnet <DEPLOYED_ADDRESS> <constructor_args>

🔑 Roles & Permissions
Role	Permissions
ADMIN_ROLE	Change fee policy/recipient, set mint hook, manage roles, pause/unpause
OP_ROLE	Manage custody BTC addresses
DEPOSIT_ROLE	Confirm BTC deposits and mint tokens
WITHDRAW_ROLE	Lock withdrawals, finalize and burn
PAUSE_ROLE	Pause the system in emergencies
🛠 Usage
Deposit Flow

BTC sent to valid custody address.

Operator confirms deposit (confirmDeposit) → mints LeadBTC.

Withdrawal Flow

User calls initiateWithdrawal → tokens escrowed.

Operator locks (lockWithdrawal).

Off-chain BTC payout executed.

Operator finalizes (finalizeWithdrawal) → burns escrowed tokens.

🧩 Integration

Proof-of-Reserve (PoR):
Add custom mintHook for deposit verification.

Fees:
Plug in FixedFeePolicy or custom implementations.

Cross-chain:
LeadBTC is OFT-based, usable across all LayerZero-supported chains.

🤝 Contributing

Contributions are welcome! Please open an issue or PR.
For security reports, please disclose privately.

📜 License

This project is licensed under the MIT License
.
