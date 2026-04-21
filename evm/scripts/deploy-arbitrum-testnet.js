require("dotenv").config({
  path: "/Users/kiran/pledgr/pledgr-solana/config.env",
});

const hre = require("hardhat");
const fs = require("fs");

const NETWORK_TOKENS = {
  arbitrumSepolia: {
    USDC: "0x75faf114eafb1bdbe2f0316df893fd58ce46aa4d",
    USDT: "0xe5b6c29411b3ad31c3613bba0145293fc9957256",
  },
  arbitrum: {
    USDC: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
    USDT: "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9",
  },
  bnbTestnet: {
    USDC: process.env.USDC_BNB_TESTNET,
    USDT: process.env.USDT_BNB_TESTNET,
  },
  bnb: {
    USDC: "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d",
    USDT: "0x55d398326f99059fF775485246999027B3197955",
  },
};

async function main() {
  const network = hre.network.name;
  console.log(`Deploying BuyOutAuction contracts to ${network}...`);
  console.log("========================================================");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    (await deployer.provider.getBalance(deployer.address)).toString()
  );

  const tokens = NETWORK_TOKENS[network];
  if (!tokens || !tokens.USDC || !tokens.USDT) {
    throw new Error(`Token addresses not configured for ${network}`);
  }

  const coOwner1 = process.env.CO_OWNER1_WALLET;
  const coOwner2 = process.env.CO_OWNER2_WALLET;
  const community = process.env.COMMUNITY_WALLET;

  if (!coOwner1 || !coOwner2 || !community) {
    throw new Error("Missing wallet addresses in config.env");
  }

  console.log("\nToken Addresses:");
  console.log("USDC:", tokens.USDC);
  console.log("USDT:", tokens.USDT);

  console.log("\nWallet Addresses:");
  console.log("coOwner1:", coOwner1);
  console.log("coOwner2:", coOwner2);
  console.log("community:", community);

  console.log("\n1. Deploying BuyOutAuctionFactory...");
  const Factory = await hre.ethers.getContractFactory("BuyOutAuctionFactory");
  const factory = await Factory.deploy(
    tokens.USDC,
    tokens.USDT,
    coOwner1,
    coOwner2,
    community
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("BuyOutAuctionFactory:", factoryAddress);

  const onChainUSDC = await factory.USDC();
  const onChainUSDT = await factory.USDT();
  console.log("\nOn-chain token verification:");
  console.log("USDC:", onChainUSDC);
  console.log("USDT:", onChainUSDT);

  console.log("\nVerifying split strategies...");
  for (let i = 0; i <= 5; i++) {
    const [creatorBps, platformBps, isActive] = await factory.getSplitStrategy(
      i
    );
    console.log(
      `  Strategy ${i}: creator=${creatorBps} platform=${platformBps} active=${isActive}`
    );
  }

  const chainId = (await hre.ethers.provider.getNetwork()).chainId.toString();

  const deploymentInfo = {
    network: network,
    chainId: chainId,
    contracts: {
      BuyOutAuctionFactory: factoryAddress,
    },
    tokens: {
      USDC: tokens.USDC,
      USDT: tokens.USDT,
    },
    wallets: {
      coOwner1: coOwner1,
      coOwner2: coOwner2,
      community: community,
    },
    deployer: deployer.address,
    deployedAt: new Date().toISOString(),
  };

  if (!fs.existsSync("deployments")) {
    fs.mkdirSync("deployments");
  }

  const filename = `deployments/${network}-buyout-auction-${Date.now()}.json`;
  fs.writeFileSync(filename, JSON.stringify(deploymentInfo, null, 2));

  console.log("\n========================================================");
  console.log("DEPLOYMENT COMPLETE");
  console.log("========================================================");
  console.log("BuyOutAuctionFactory:", factoryAddress);
  console.log("Deployment saved to:", filename);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
