AnonymousBugReports — Encrypted Bug Reports on Zama FHEVM

Anonymous (EVM-pseudonymous) bug reports with private severity (1–5). Severity is encrypted on the frontend; the smart
contract aggregates per projectId the encrypted sum and count, and the frontend decrypts the resulting handles via Zama
Relayer SDK. Individual scores are never revealed—only aggregates.

Tech stack: Solidity ^0.8.24 · Zama FHEVM @fhevm/solidity/lib/FHE.sol · Relayer SDK @zama-fhe/relayer-sdk · Sepolia

✨ Features

Private severity: each 1–5 score is encrypted on the client.

On-chain FHE aggregation: the contract sums valid scores and counts valid reports using encrypted values.

Publicly decryptable aggregates: the contract marks aggregates as publicly decryptable—any client can read them through
Relayer SDK.

Range guard 1..5: out-of-range inputs contribute zero—without revealing the raw score.

Simple integration: the frontend signs via EIP-712 and calls publicDecrypt() / userDecrypt() to read values.

🧩 Architecture & Data Flow

User enters severity 1..5.

Frontend encrypts value with Relayer SDK → obtains externalEuint8 + proof.

Contract submitReport(projectId, contentHash, severityExt, proof):

privately checks the range,

updates encrypted sum and count,

calls FHE.makePubliclyDecryptable(...) for aggregates,

emits ReportSubmitted with bytes32 handles (severityHandle, sumHandle, countHandle).

Frontend reads latest handles (from the event or via getAggregateHandles) and:

uses publicDecrypt(handle) to obtain sum/count,

computes average locally: average = sum / count.

The contract does not divide on-chain; averaging is done client-side after decryption.

📦 Smart Contract // SPDX-License-Identifier: MIT pragma solidity ^0.8.24;

import {FHE, ebool, euint8, euint64, externalEuint8} from "@fhevm/solidity/lib/FHE.sol"; import {SepoliaConfig} from
"@fhevm/solidity/config/ZamaConfig.sol";

contract AnonymousBugReports is SepoliaConfig { // ...see contracts/AnonymousBugReports.sol }

Public methods

version() -> string

projectExists(uint256 projectId) -> bool

getAggregateHandles(uint256 projectId) -> (bytes32 sumHandle, bytes32 countHandle)

submitReport(uint256 projectId, bytes32 contentHash, externalEuint8 severityExt, bytes proof)

Owner-only

resetAggregates(uint256 projectId) — reset aggregates to zero (new handles).

shareAggregates(uint256 projectId, address viewer) — grant a specific address decrypt rights to current aggregates
(optional if already public).

Events

ProjectInitialized(uint256 projectId)

ReportSubmitted(projectId, contentHash, severityHandle, sumHandle, countHandle)

AggregatesReset(uint256 projectId)

🛠️ Stack & Requirements

Solidity: ^0.8.24

Zama FHEVM: @fhevm/solidity (official FHE.sol only)

Relayer SDK: @zama-fhe/relayer-sdk

Network: Sepolia (chainId 11155111)

Node.js: 18+ for the frontend

Wallet: MetaMask + test ETH

⚠️ Do not use deprecated/unsupported packages such as @fhevm-js/relayer or @fhenixprotocol/....

🚀 Quick Start

1. Install npm install

If you use Hardhat:

npx hardhat compile

2. Deploy to Sepolia (Hardhat example) npx hardhat run scripts/deploy.ts --network sepolia

Save the deployed contract address to your env/config, e.g.:

VITE_CONTRACT_ADDRESS=0xYourDeployedAddress

🌐 Frontend: Relayer SDK

Minimal examples with the official Relayer SDK. Use createInstance, then createEncryptedInput(...), followed by
publicDecrypt(...) or userDecrypt(...).

Initialize SDK import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk";

const relayer = await createInstance({ ...SepoliaConfig, // if using a bundler/SPA, the SDK may auto-init workers under
the hood });

Submit a report (encrypt severity 1–5) import { ethers } from "ethers"; import abi from
"./abi/AnonymousBugReports.json";

const CONTRACT_ADDRESS = import.meta.env.VITE_CONTRACT_ADDRESS;

export async function submitReport(projectId: bigint, contentHash: string, severity: number) { // 1) Encrypt input const
enc = await relayer.createEncryptedInput({ types: ["euint8"], values: [severity], });

const { externalValues, proof } = await enc.toExternal(); // externalValues[0] corresponds to externalEuint8 in the
contract

// 2) Contract call const provider = new ethers.BrowserProvider(window.ethereum); const signer = await
provider.getSigner(); const c = new ethers.Contract(CONTRACT_ADDRESS, abi, signer);

const tx = await c.submitReport( projectId, contentHash, // bytes32 externalValues[0], // externalEuint8
(ABI-compatible) proof // bytes ); await tx.wait(); }

Read aggregates (publicDecrypt) export async function readAggregates(projectId: bigint) { const provider = new
ethers.BrowserProvider(window.ethereum); const c = new ethers.Contract(CONTRACT_ADDRESS, abi, provider);

const [sumHandle, countHandle] = await c.getAggregateHandles(projectId);

// Public decrypt, because the contract called makePubliclyDecryptable(...) const [sum, count] = await
relayer.publicDecrypt([sumHandle, countHandle]);

const average = Number(count) > 0 ? Number(sum) / Number(count) : 0; return { sum: Number(sum), count: Number(count),
average }; }

Private decryption for a user (userDecrypt)

If you used shareAggregates to grant access only to specific addresses:

export async function readPrivateAggregates(projectId: bigint) { const provider = new
ethers.BrowserProvider(window.ethereum); const signer = await provider.getSigner(); const user = await
signer.getAddress();

const c = new ethers.Contract(CONTRACT_ADDRESS, abi, provider); const [sumHandle, countHandle] = await
c.getAggregateHandles(projectId);

// SDK will request an EIP-712 signature and return values decrypted for this user const [sum, count] = await
relayer.userDecrypt([sumHandle, countHandle], { user, contracts: [CONTRACT_ADDRESS] });

const average = Number(count) > 0 ? Number(sum) / Number(count) : 0; return { sum: Number(sum), count: Number(count),
average }; }

Note: helper method names (e.g., toExternal()) can vary across SDK versions. Key building blocks:
createEncryptedInput(...), publicDecrypt(...), userDecrypt(...), and SepoliaConfig from the official
@zama-fhe/relayer-sdk.

📁 Project Structure . ├─ contracts/ │ └─ AnonymousBugReports.sol ├─ scripts/ │ └─ deploy.ts ├─ frontend/ │ └─ public/ │
└─ index.html # main SPA entry lives here ├─ abi/ │ └─ AnonymousBugReports.json ├─ hardhat.config.ts ├─ package.json └─
README.md

If your SPA reads from a static frontend/public/index.html, remember to set your contract address inside that file (or
wire it from env at build time).

🔒 Security & Invariants

No FHE ops in view/pure: all FHE operations happen in state-changing txs.

ACL: the contract uses FHE.allowThis(...) and FHE.makePubliclyDecryptable(...) for correct access control and public
decryptability of aggregates.

Range 1..5: validation is private; invalid values do not affect aggregates.

No on-chain division: average is computed client-side after decryption.

Type constraints: euint64 supports arithmetic (add/sub, etc.). euint256 / eaddress do not support arithmetic—only
comparisons/bitwise.

Public aggregates: once made publicly decryptable, anyone can publicDecrypt. If you need restricted access, prefer
shareAggregates(...) and skip public decrypt.

✅ Integrator Checklist

Deploy to Sepolia; save the contract address.

Initialize @zama-fhe/relayer-sdk with createInstance(SepoliaConfig).

For submissions: createEncryptedInput(...) → submitReport(...).

For reads: getAggregateHandles(...) → publicDecrypt(...) or userDecrypt(...).

Compute average = sum / count on the frontend.

(Optional) Use shareAggregates(...) for private access rather than public decrypt.

🧪 Testing Notes

Validate correctness:

severity = 0 or 6 has no effect on sum and count.

successive calls monotonically increase aggregates (when valid).

Inspect ReportSubmitted events—they carry the latest handles.

📜 License

MIT — see LICENSE.

🙌 Acknowledgements

Thanks to Zama FHEVM and the Relayer SDK for enabling secure on-chain confidential computation.
