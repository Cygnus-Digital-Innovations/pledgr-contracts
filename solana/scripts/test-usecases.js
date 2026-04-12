const web3 = require("@solana/web3.js");
const {
  Program,
  AnchorProvider,
  Wallet,
  getProvider,
} = require("@coral-xyz/anchor");
const config = require("./config");
const idl = require("../idl/pledgr.json");

const ENV = process.argv[2] || "devnet";
const cfg = config[ENV];

const PROGRAM_ID = new web3.PublicKey(cfg.programId);

async function getWallet() {
  const keyPath =
    process.env.SOLANA_KEYPAIR || process.env.HOME + "/.config/solana/id.json";
  const secretKey = JSON.parse(require("fs").readFileSync(keyPath, "utf-8"));
  return web3.Keypair.fromSecretKey(new Uint8Array(secretKey));
}

async function getConnection() {
  return new web3.Connection(cfg.rpcUrl, "confirmed");
}

async function main() {
  console.log(`\n=== Testing Pledgr Program on ${ENV} ===\n`);

  const wallet = await getWallet();
  const connection = await getConnection();

  const provider = new AnchorProvider(connection, new Wallet(wallet), {
    commitment: "confirmed",
  });
  const program = new Program(idl, PROGRAM_ID, provider);

  // Derive config PDA
  const [configPda] = web3.PublicKey.findProgramAddressSync(
    [Buffer.from("processor")],
    PROGRAM_ID
  );
  console.log("Config PDA:", configPda.toString());

  // Get test wallets
  const subscriber = wallet.publicKey;
  const creator = web3.Keypair.generate().publicKey;

  console.log("Test Subscriber:", subscriber.toString());
  console.log("Test Creator:", creator.toString());

  try {
    // Test 1: Add Supported Token (USDT)
    console.log("\n--- Test 1: Add Supported Token (USDT) ---");
    const usdtMint = new web3.PublicKey(cfg.usdtMint);

    const addTokenTx = await program.methods
      .addSupportedToken()
      .accounts({
        config: configPda,
        tokenMint: usdtMint,
        authority: wallet.publicKey,
      })
      .transaction();

    addTokenTx.feePayer = wallet.publicKey;
    const { blockhash: bh1 } = await connection.getLatestBlockhash();
    addTokenTx.recentBlockhash = bh1;

    const addTokenSig = await connection.sendTransaction(addTokenTx, [wallet]);
    await connection.confirmTransaction(addTokenSig, "confirmed");
    console.log("Added USDT token. Sig:", addTokenSig.substring(0, 20) + "...");

    // Test 2: Subscribe
    console.log("\n--- Test 2: Subscribe ---");
    const subscriptionId = Array(32)
      .fill(0)
      .map(() => Math.floor(Math.random() * 256));
    const subscribeTx = await program.methods
      .subscribe({
        subscriptionId,
        tierIndex: 0,
        paymentToken: usdtMint,
        paymentAmount: 1000000, // 1 USDT
        referrer: null,
      })
      .accounts({
        config: configPda,
      })
      .transaction();

    subscribeTx.feePayer = wallet.publicKey;
    const { blockhash: bh2 } = await connection.getLatestBlockhash();
    subscribeTx.recentBlockhash = bh2;

    const subscribeSig = await connection.sendTransaction(subscribeTx, [
      wallet,
    ]);
    await connection.confirmTransaction(subscribeSig, "confirmed");
    console.log("Subscribed! Sig:", subscribeSig.substring(0, 20) + "...");

    // Derive subscription PDA
    const [subscriptionPda] = web3.PublicKey.findProgramAddressSync(
      [Buffer.from("subscription"), Buffer.from(subscriptionId)],
      PROGRAM_ID
    );
    console.log("Subscription PDA:", subscriptionPda.toString());

    // Test 3: Process Payment
    console.log("\n--- Test 3: Process Payment ---");
    const paymentId = Array(32)
      .fill(0)
      .map(() => Math.floor(Math.random() * 256));

    // First, create subscriber's token account and fund it
    const subscriberTokenAccount = web3.PublicKey.findProgramAddressSync(
      [
        subscriber.toBuffer(),
        web3.TokenInstructions.TOKEN_PROGRAM_ID.toBuffer(),
        usdtMint.toBuffer(),
      ],
      new web3.PublicKey("ATokenGPvbdGVxr1b2hvZ1iqA2U8w1C9huqjW9pSALwGi")
    )[0];

    console.log("Testing process_payment requires token account setup...");
    console.log("(Skipping actual payment test - needs token funding)");

    // Test 4: Get Subscription Info
    console.log("\n--- Test 4: Get Subscription Info ---");
    const subscriptionInfo = await program.account.subscription.fetch(
      subscriptionPda
    );
    console.log("Subscription Status:", subscriptionInfo.status);
    console.log("Subscriber:", subscriptionInfo.subscriber.toString());

    // Test 5: Upgrade Subscription
    console.log("\n--- Test 5: Upgrade Subscription ---");
    const upgradeTx = await program.methods
      .upgradeSubscription({ tierIndex: 1 })
      .accounts({
        subscription: subscriptionPda,
        config: configPda,
      })
      .transaction();

    upgradeTx.feePayer = wallet.publicKey;
    const { blockhash: bh3 } = await connection.getLatestBlockhash();
    upgradeTx.recentBlockhash = bh3;

    const upgradeSig = await connection.sendTransaction(upgradeTx, [wallet]);
    await connection.confirmTransaction(upgradeSig, "confirmed");
    console.log("Upgraded! Sig:", upgradeSig.substring(0, 20) + "...");

    // Test 6: Downgrade Subscription
    console.log("\n--- Test 6: Downgrade Subscription ---");
    const downgradeTx = await program.methods
      .downgradeSubscription({ tierIndex: 0 })
      .accounts({
        subscription: subscriptionPda,
        config: configPda,
      })
      .transaction();

    downgradeTx.feePayer = wallet.publicKey;
    const { blockhash: bh4 } = await connection.getLatestBlockhash();
    downgradeTx.recentBlockhash = bh4;

    const downgradeSig = await connection.sendTransaction(downgradeTx, [
      wallet,
    ]);
    await connection.confirmTransaction(downgradeSig, "confirmed");
    console.log("Downgraded! Sig:", downgradeSig.substring(0, 20) + "...");

    // Test 7: Cancel Subscription
    console.log("\n--- Test 7: Cancel Subscription ---");
    const cancelTx = await program.methods
      .cancelSubscription()
      .accounts({
        subscription: subscriptionPda,
        config: configPda,
        authority: wallet.publicKey,
      })
      .transaction();

    cancelTx.feePayer = wallet.publicKey;
    const { blockhash: bh5 } = await connection.getLatestBlockhash();
    cancelTx.recentBlockhash = bh5;

    const cancelSig = await connection.sendTransaction(cancelTx, [wallet]);
    await connection.confirmTransaction(cancelSig, "confirmed");
    console.log("Cancelled! Sig:", cancelSig.substring(0, 20) + "...");

    // Test 8: Close Subscription (get rent back)
    console.log("\n--- Test 8: Close Subscription ---");
    const closeTx = await program.methods
      .closeSubscription()
      .accounts({
        subscription: subscriptionPda,
        config: configPda,
        authority: wallet.publicKey,
        recipient: wallet.publicKey,
      })
      .transaction();

    closeTx.feePayer = wallet.publicKey;
    const { blockhash: bh6 } = await connection.getLatestBlockhash();
    closeTx.recentBlockhash = bh6;

    const closeSig = await connection.sendTransaction(closeTx, [wallet]);
    await connection.confirmTransaction(closeSig, "confirmed");
    console.log("Closed! Sig:", closeSig.substring(0, 20) + "...");

    console.log("\n=== All Tests Passed! ===\n");
  } catch (e) {
    console.error("Error:", e.message);
    if (e.message.includes("already in use")) {
      console.log(
        "\nNote: Some accounts may already exist from previous tests."
      );
    }
  }
}

main().catch(console.error);
