const web3 = require("@solana/web3.js");
const config = require("./config");

const ENV = process.argv[2] || "devnet";
const cfg = config[ENV];

const PROGRAM_ID = new web3.PublicKey(cfg.programId);

async function main() {
  console.log(`\n=== Testing Pledgr Program on ${ENV} ===\n`);

  const keyPath =
    process.env.SOLANA_KEYPAIR || process.env.HOME + "/.config/solana/id.json";
  const secretKey = JSON.parse(require("fs").readFileSync(keyPath, "utf-8"));
  const wallet = web3.Keypair.fromSecretKey(new Uint8Array(secretKey));

  const connection = new web3.Connection(cfg.rpcUrl, "confirmed");

  // Derive config PDA
  const [configPda] = web3.PublicKey.findProgramAddressSync(
    [Buffer.from("processor")],
    PROGRAM_ID
  );
  console.log("Config PDA:", configPda.toString());
  console.log("Wallet:", wallet.publicKey.toString());
  console.log("Program:", PROGRAM_ID.toString());

  // Get config account info
  const configInfo = await connection.getAccountInfo(configPda);
  if (!configInfo) {
    console.log("ERROR: Config not initialized!");
    return;
  }
  console.log("Config exists! Data length:", configInfo.data.length);

  // Test 1: Add Supported Token (USDC)
  console.log("\n--- Test 1: Add Supported Token (USDC) ---");
  const usdcMint = new web3.PublicKey(cfg.usdcMint);

  // Build instruction using IDL discriminator
  // add_supported_token: 109, 142, 133, 205, 240, 28, 197, 245
  const addTokenIx = new web3.TransactionInstruction({
    programId: PROGRAM_ID,
    keys: [
      { pubkey: configPda, isWritable: true, isSigner: false },
      { pubkey: usdcMint, isWritable: false, isSigner: false },
      { pubkey: wallet.publicKey, isWritable: false, isSigner: true },
    ],
    data: Buffer.from([109, 142, 133, 205, 240, 28, 197, 245]),
  });

  try {
    const tx1 = new web3.Transaction().add(addTokenIx);
    tx1.feePayer = wallet.publicKey;
    const { blockhash: bh1 } = await connection.getLatestBlockhash();
    tx1.recentBlockhash = bh1;

    const sig1 = await connection.sendTransaction(tx1, [wallet]);
    await connection.confirmTransaction(sig1, "confirmed");
    console.log("Added USDC token. Sig:", sig1.substring(0, 30) + "...");
  } catch (e) {
    console.log("Note:", e.message.substring(0, 100));
  }

  // Test 2: Get Config Info
  console.log("\n--- Test 2: Get Config Info ---");
  const configData = await connection.getAccountInfo(configPda);
  if (configData) {
    // Parse config - first 8 bytes are discriminator
    const coOwnerOne = new web3.PublicKey(configData.data.slice(8, 40));
    const coOwnerTwo = new web3.PublicKey(configData.data.slice(40, 72));
    const coOwnerThree = new web3.PublicKey(configData.data.slice(72, 104));
    const usdtMintParsed = new web3.PublicKey(configData.data.slice(104, 136));
    const usdcMintParsed = new web3.PublicKey(configData.data.slice(136, 168));

    console.log("Co-Owner One:", coOwnerOne.toString());
    console.log("Co-Owner Two:", coOwnerTwo.toString());
    console.log("Co-Owner Three:", coOwnerThree.toString());
    console.log("USDT Mint:", usdtMintParsed.toString());
    console.log("USDC Mint:", usdcMintParsed.toString());
  }

  // Test 3: Toggle Pause
  console.log("\n--- Test 3: Toggle Pause ---");
  // toggle_pause: 117, 114, 114, 101, 114, 114, 105, 100
  const togglePauseIx = new web3.TransactionInstruction({
    programId: PROGRAM_ID,
    keys: [
      { pubkey: configPda, isWritable: true, isSigner: false },
      { pubkey: wallet.publicKey, isWritable: false, isSigner: true },
    ],
    data: Buffer.from([117, 114, 114, 101, 114, 114, 105, 100]),
  });

  try {
    const tx3 = new web3.Transaction().add(togglePauseIx);
    tx3.feePayer = wallet.publicKey;
    const { blockhash: bh3 } = await connection.getLatestBlockhash();
    tx3.recentBlockhash = bh3;

    const sig3 = await connection.sendTransaction(tx3, [wallet]);
    await connection.confirmTransaction(sig3, "confirmed");
    console.log("Toggled pause. Sig:", sig3.substring(0, 30) + "...");
  } catch (e) {
    console.log("Error:", e.message.substring(0, 100));
  }

  console.log("\n=== Basic Tests Complete ===\n");
}

main().catch(console.error);
