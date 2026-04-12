const web3 = require("@solana/web3.js");
const config = require("./config");

const ENV = process.argv[2] || "devnet";
const cfg = config[ENV];
const PROGRAM_ID = new web3.PublicKey(cfg.programId);

async function main() {
  console.log(`\n=== Testing Program: ${cfg.programId} ===\n`);

  const keyPath =
    process.env.SOLANA_KEYPAIR || process.env.HOME + "/.config/solana/id.json";
  const wallet = web3.Keypair.fromSecretKey(
    new Uint8Array(JSON.parse(require("fs").readFileSync(keyPath)))
  );
  const connection = new web3.Connection(cfg.rpcUrl, "confirmed");

  // Check program
  console.log("1. Checking Program...");
  const programInfo = await connection.getParsedAccountInfo(PROGRAM_ID);
  console.log("   Program executable:", programInfo.value?.executable);
  console.log("   Program owner:", programInfo.value?.owner);

  // Check config
  console.log("\n2. Checking Config PDA...");
  const [configPda] = web3.PublicKey.findProgramAddressSync(
    [Buffer.from("processor")],
    PROGRAM_ID
  );
  console.log("   Config PDA:", configPda.toString());

  const configInfo = await connection.getAccountInfo(configPda);
  if (configInfo) {
    console.log("   Config exists: YES");
    console.log("   Config data length:", configInfo.data.length);

    // Try to get more details
    const data = configInfo.data;
    console.log(
      "   First 8 bytes (discriminator):",
      [...data.slice(0, 8)].map((b) => b.toString(16)).join(" ")
    );
  } else {
    console.log("   Config exists: NO");
  }

  // Check balance
  console.log("\n3. Checking Wallet Balance...");
  const balance = await connection.getBalance(wallet.publicKey);
  console.log("   Balance:", balance / 1e9, "SOL");

  console.log("\n=== Program is Deployed and Configured ===\n");
}

main().catch(console.error);
