import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";

/**
 * Deploys AnonymousBugReports (no constructor args).
 *
 * Usage:
 *   yarn hardhat deploy --network sepolia --tags AnonymousBugReports
 *   yarn hardhat deploy --network localhost --tags AnonymousBugReports
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network, run, ethers } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  log(`\n🛡️ Deploying AnonymousBugReports from ${deployer} on ${network.name}...`);

  const deployed = await deploy("AnonymousBugReports", {
    from: deployer,
    args: [],
    log: true,
    waitConfirmations: network.live ? 3 : 1,
    skipIfAlreadyDeployed: true,
  });

  log(`✅ AnonymousBugReports address: ${deployed.address}`);

  // --- Post-deploy sanity: убедимся, что контракт тот, что нужен (version())
  try {
    const abi = await ethers.getContractAt("AnonymousBugReports", deployed.address);
    const ver: string = await abi.version();
    log(`ℹ️ version(): ${ver}`);
  } catch (e: any) {
    log(`⚠️ Skipping version() check: ${e?.message || e}`);
  }

  // Верификация
  if (network.live && (deployed as any).newlyDeployed) {
    try {
      await run("verify:verify", {
        address: deployed.address,
        constructorArguments: [],
      });
      log("🔎 Verified on block explorer (if supported).");
    } catch (e: any) {
      const msg = e?.message || String(e);
      if (!msg.includes("Already Verified")) log(`⚠️ Verification skipped: ${msg}`);
      else log("ℹ️ Already verified.");
    }
  }
};

export default func;
func.id = "deploy_anonymous_bug_reports";
func.tags = ["AnonymousBugReports", "FHEVM", "Bugs"];
