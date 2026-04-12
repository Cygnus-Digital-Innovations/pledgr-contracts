const web3 = require("@solana/web3.js");
const config = require("./config");

const ENV = process.argv[2] || "devnet";
const cfg = config[ENV];

const PROGRAM_ID = new web3.PublicKey(cfg.programId);
const USDT_MINT = new web3.PublicKey(cfg.usdtMint);
const USDC_MINT = new web3.PublicKey(cfg.usdcMint);
const CO_OWNER_ONE = new web3.PublicKey(cfg.coOwnerOne);
const CO_OWNER_TWO = new web3.PublicKey(cfg.coOwnerTwo);
const CO_OWNER_THREE = new web3.PublicKey(cfg.coOwnerThree);

async function main() {
  console.log(`Initializing ${ENV}...`);

  const connection = new web3.Connection(cfg.rpcUrl, "confirmed");

  const keyPath =
    process.env.SOLANA_KEYPAIR || process.env.HOME + "/.config/solana/id.json";
  const wallet = web3.Keypair.fromSecretKey(
    new Uint8Array(JSON.parse(require("fs").readFileSync(keyPath, "utf-8")))
  );

  const [configPda] = web3.PublicKey.findProgramAddressSync(
    [Buffer.from("processor")],
    PROGRAM_ID
  );
  console.log("Config PDA:", configPda.toString());

  const existing = await connection.getAccountInfo(configPda);
  console.log("Existing:", existing ? "yes" : "no");

  if (existing) {
    console.log("Config already exists! Skipping initialization.");
    return;
  }

  console.log("Initializing new config...");

  const data = Buffer.alloc(168);
  data.writeUInt8(0xaf, 0);
  data.writeUInt8(0xaf, 1);
  data.writeUInt8(0x6d, 2);
  data.writeUInt8(0x1f, 3);
  data.writeUInt8(0x0d, 4);
  data.writeUInt8(0x98, 5);
  data.writeUInt8(0x9b, 6);
  data.writeUInt8(0xed, 7);
  CO_OWNER_ONE.toBuffer().copy(data, 8);
  CO_OWNER_TWO.toBuffer().copy(data, 40);
  CO_OWNER_THREE.toBuffer().copy(data, 72);
  USDT_MINT.toBuffer().copy(data, 104);
  USDC_MINT.toBuffer().copy(data, 136);

  const instruction = new web3.TransactionInstruction({
    programId: PROGRAM_ID,
    keys: [
      { pubkey: configPda, isWritable: true, isSigner: false },
      { pubkey: wallet.publicKey, isWritable: true, isSigner: true },
      {
        pubkey: web3.SystemProgram.programId,
        isWritable: false,
        isSigner: false,
      },
    ],
    data: data,
  });

  const transaction = new web3.Transaction().add(instruction);
  transaction.feePayer = wallet.publicKey;
  const { blockhash } = await connection.getLatestBlockhash();
  transaction.recentBlockhash = blockhash;

  try {
    const tx = await web3.sendAndConfirmTransaction(
      connection,
      transaction,
      [wallet],
      { commitment: "confirmed" }
    );
    console.log("Success! Tx:", tx);
  } catch (e) {
    console.error("Error:", e.message);
  }
}

main().catch(console.error);
