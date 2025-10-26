# AnonymousBugReports — Encrypted Bug Reports on Zama FHEVM

Anonymous (EVM-pseudonymous) bug reports with **private severity (1–5)**.  
Severity is encrypted on the frontend; the smart contract aggregates per `projectId` the encrypted **sum** and **count**, and the frontend decrypts the resulting handles via Zama Relayer SDK. **Individual scores are never revealed — only aggregates.**

> **Tech stack**: Solidity ^0.8.24 · Zama FHEVM `@fhevm/solidity/lib/FHE.sol` · Relayer SDK `@zama-fhe/relayer-sdk` · Network: Sepolia

---

## Table of Contents

- [Features](#-features)
- [Architecture & Data Flow](#-architecture--data-flow)
- [Smart Contract](#-smart-contract)
- [Stack & Requirements](#-stack--requirements)
- [Quick Start](#-quick-start)
- [Frontend (Relayer SDK)](#-frontend-relayer-sdk)
  - [Initialize SDK](#initialize-sdk)
  - [Submit a report](#submit-a-report-encrypt-severity-15)
  - [Read aggregates (public)](#read-aggregates-publicdecrypt)
  - [Read aggregates (private)](#private-decryption-userdecrypt)
- [Project Structure](#-project-structure)
- [Security & Invariants](#-security--invariants)
- [Integrator Checklist](#-integrator-checklist)
- [Testing Notes](#-testing-notes)
- [License](#-license)
- [Acknowledgements](#-acknowledgements)

---

## ✨ Features

- **Private severity**: each 1–5 score is encrypted on the client.
- **On-chain FHE aggregation**: encrypted **sum** of valid scores and **count** of valid reports.
- **Publicly decryptable aggregates**: anyone can read aggregates when marked public by the contract.
- **Range guard 1..5**: out-of-range inputs contribute zero — without revealing the raw score.
- **Simple integration**: frontend uses EIP-712 flows and Relayer SDK `publicDecrypt()` / `userDecrypt()`.

---

## 🧩 Architecture & Data Flow

1. User enters severity **1..5**.
2. Frontend **encrypts** value with Relayer SDK → obtains `externalEuint8` + `proof`.
3. Contract `submitReport(projectId, contentHash, severityExt, proof)`:
   - privately checks range,
   - updates encrypted `sum` and `count`,
   - calls `FHE.makePubliclyDecryptable(...)` for aggregates,
   - emits `ReportSubmitted` with bytes32 handles (`severityHandle`, `sumHandle`, `countHandle`).
4. Frontend reads latest handles (event or `getAggregateHandles`) and:
   - uses `publicDecrypt(handle)` to obtain `sum`/`count`,
   - computes **average** locally: `average = sum / count`.

> The contract **does not** divide on-chain; averaging is done client-side after decryption.

---

## 📦 Smart Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint8, euint64, externalEuint8} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

contract AnonymousBugReports is SepoliaConfig {
  // See contracts/AnonymousBugReports.sol
}
````

**Public methods**

* `version() -> string`
* `projectExists(uint256 projectId) -> bool`
* `getAggregateHandles(uint256 projectId) -> (bytes32 sumHandle, bytes32 countHandle)`
* `submitReport(uint256 projectId, bytes32 contentHash, externalEuint8 severityExt, bytes proof)`

**Owner-only**

* `resetAggregates(uint256 projectId)` — reset aggregates to zero (new handles).
* `shareAggregates(uint256 projectId, address viewer)` — grant decrypt rights to current aggregates (optional if public).

**Events**

* `ProjectInitialized(uint256 projectId)`
* `ReportSubmitted(projectId, contentHash, severityHandle, sumHandle, countHandle)`
* `AggregatesReset(uint256 projectId)`

---

## 🛠️ Stack & Requirements

* **Solidity**: ^0.8.24
* **Zama FHEVM**: `@fhevm/solidity` (official `FHE.sol` only)
* **Relayer SDK**: `@zama-fhe/relayer-sdk`
* **Network**: Sepolia (`11155111`)
* **Node.js**: 18+ for the frontend
* **Wallet**: MetaMask + test ETH

> ⚠️ Avoid deprecated/unsupported packages such as `@fhevm-js/relayer` or `@fhenixprotocol/...`.

---

## 🚀 Quick Start

### 1) Install

```bash
npm install
```

If using Hardhat:

```bash
npx hardhat compile
```

### 2) Deploy to Sepolia (Hardhat example)

```bash
npx hardhat run scripts/deploy.ts --network sepolia
```

Save the contract address in your env/config:

```bash
VITE_CONTRACT_ADDRESS=0xYourDeployedAddress
```

---

## 🌐 Frontend (Relayer SDK)

> Minimal examples with the official **Relayer SDK**.
> Use `createInstance` → `createEncryptedInput(...)` → `publicDecrypt(...)` / `userDecrypt(...)`.

### Initialize SDK

```ts
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk";

export const relayer = await createInstance({
  ...SepoliaConfig,
  // If using a bundler/SPA, the SDK may auto-init workers under the hood.
});
```

### Submit a report (encrypt severity 1–5)

```ts
import { ethers } from "ethers";
import abi from "./abi/AnonymousBugReports.json";
import { relayer } from "./relayer"; // see init above

const CONTRACT_ADDRESS = import.meta.env.VITE_CONTRACT_ADDRESS;

export async function submitReport(projectId: bigint, contentHash: string, severity: number) {
  // 1) Encrypt input
  const enc = await relayer.createEncryptedInput({
    types: ["euint8"],
    values: [severity],
  });

  const { externalValues, proof } = await enc.toExternal(); 
  // externalValues[0] -> externalEuint8 in the contract

  // 2) Contract call
  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer = await provider.getSigner();
  const c = new ethers.Contract(CONTRACT_ADDRESS, abi, signer);

  const tx = await c.submitReport(
    projectId,
    contentHash,                   // bytes32
    externalValues[0],             // externalEuint8 (ABI-compatible)
    proof                          // bytes
  );
  await tx.wait();
}
```

### Read aggregates (publicDecrypt)

```ts
import { ethers } from "ethers";
import abi from "./abi/AnonymousBugReports.json";
import { relayer } from "./relayer";

const CONTRACT_ADDRESS = import.meta.env.VITE_CONTRACT_ADDRESS;

export async function readAggregates(projectId: bigint) {
  const provider = new ethers.BrowserProvider(window.ethereum);
  const c = new ethers.Contract(CONTRACT_ADDRESS, abi, provider);

  const [sumHandle, countHandle] = await c.getAggregateHandles(projectId);

  // Public decrypt, because the contract called makePubliclyDecryptable(...)
  const [sum, count] = await relayer.publicDecrypt([sumHandle, countHandle]);

  const average = Number(count) > 0 ? Number(sum) / Number(count) : 0;
  return { sum: Number(sum), count: Number(count), average };
}
```

### Private decryption (userDecrypt)

```ts
import { ethers } from "ethers";
import abi from "./abi/AnonymousBugReports.json";
import { relayer } from "./relayer";

const CONTRACT_ADDRESS = import.meta.env.VITE_CONTRACT_ADDRESS;

export async function readPrivateAggregates(projectId: bigint) {
  const provider = new ethers.BrowserProvider(window.ethereum);
  const signer = await provider.getSigner();
  const user = await signer.getAddress();

  const c = new ethers.Contract(CONTRACT_ADDRESS, abi, provider);
  const [sumHandle, countHandle] = await c.getAggregateHandles(projectId);

  // SDK requests an EIP-712 signature and returns values decrypted for this user
  const [sum, count] = await relayer.userDecrypt([sumHandle, countHandle], {
    user,
    contracts: [CONTRACT_ADDRESS],
  });

  const average = Number(count) > 0 ? Number(sum) / Number(count) : 0;
  return { sum: Number(sum), count: Number(count), average };
}
```

---

## 📁 Project Structure

```
.
├─ contracts/
│  └─ AnonymousBugReports.sol
├─ scripts/
│  └─ deploy.ts
├─ frontend/
│  └─ public/
│     └─ index.html          # main SPA entry lives here
├─ abi/
│  └─ AnonymousBugReports.json
├─ hardhat.config.ts
├─ package.json
└─ README.md
```

> If your SPA reads from a static `frontend/public/index.html`, set your contract address there or inject it from env at build time.

---

## 🔒 Security & Invariants

* **No FHE in view/pure**: FHE ops only in state-changing transactions.
* **ACL**: uses `FHE.allowThis(...)` and `FHE.makePubliclyDecryptable(...)` for access/public decryptability of aggregates.
* **Range 1..5**: validation is private; invalid values don’t affect aggregates.
* **No on-chain division**: compute `average = sum / count` on the client.
* **Type constraints**: `euint64` supports arithmetic (`add/sub`, etc.). `euint256`/`eaddress` **do not** support arithmetic — only comparisons/bitwise.
* **Public aggregates**: once made public, anyone can `publicDecrypt`. For restricted access, use `shareAggregates(...)` and skip the public flag.

---

## ✅ Integrator Checklist

* [ ] Deploy to Sepolia; save the contract address.
* [ ] Initialize `@zama-fhe/relayer-sdk` with `createInstance(SepoliaConfig)`.
* [ ] Submissions: `createEncryptedInput(...)` → `submitReport(...)`.
* [ ] Reads: `getAggregateHandles(...)` → `publicDecrypt(...)` or `userDecrypt(...)`.
* [ ] Compute `average = sum / count` on the frontend.
* [ ] (Optional) Use `shareAggregates(...)` for private access instead of public decrypt.

---

## 🧪 Testing Notes

* **Correctness**:

  * `severity = 0` or `6` has **no** effect on `sum` and `count`.
  * successive valid calls monotonically increase aggregates.
* Inspect `ReportSubmitted` events — they carry the latest handles.

---

## 📜 License

MIT — see `LICENSE`.

---

## 🙌 Acknowledgements

Thanks to **Zama FHEVM** and the **Relayer SDK** for enabling secure on-chain confidential computation.

```
```
