#!/bin/bash
# Deploy script - Usage: ./deploy.sh [devnet|mainnet]
# 
# For fresh deployment:
#   1. Generate keypair: solana-keygen new -o target/deploy/pledgr-keypair.json
#   2. Get ID: solana-keygen pubkey target/deploy/pledgr-keypair.json
#   3. Add to config.js
#   4. Run: ./deploy.sh mainnet

ENV=${1:-devnet}

if [ "$ENV" != "devnet" ] && [ "$ENV" != "mainnet" ]; then
  echo "Usage: ./deploy.sh [devnet|mainnet]"
  exit 1
fi

echo "========================================="
echo "Deploying to $ENV"
echo "========================================="

# Get config
PROGRAM_ID=$(node -e "console.log(require('./scripts/config').$ENV.programId)")
RPC_URL=$(node -e "console.log(require('./scripts/config').$ENV.rpcUrl)")

solana config set --url "$RPC_URL"
echo "RPC: $RPC_URL"

# Check balance
BALANCE=$(solana balance | awk '{print $1}')
echo "Current balance: $BALANCE SOL"

# Check required SOL
REQUIRED_SOL=3.5
BALANCE_NUM=$(echo $BALANCE | tr -d '.')

if (( BALANCE_NUM < 3500000000 )); then
  echo ""
  echo "ERROR: Not enough SOL!"
  echo "Required: ~$REQUIRED_SOL SOL"
  echo "Available: $BALANCE SOL"
  echo ""
  exit 1
fi

if [ -z "$PROGRAM_ID" ]; then
  echo ""
  echo "ERROR: No program ID configured!"
  echo ""
  echo "For FRESH deployment:"
  echo "  1. Generate keypair:"
  echo "     solana-keygen new -o target/deploy/pledgr-keypair.json"
  echo ""
  echo "  2. Get program ID:"
  echo "     solana-keygen pubkey target/deploy/pledgr-keypair.json"
  echo ""
  echo "  3. Add to config.js, e.g.:"
  echo '     mainnet: { programId: "YOUR_NEW_ID", ... }'
  echo ""
  echo "  4. Run deploy again"
  echo ""
  exit 1
fi

echo ""
echo "Using Program ID: $PROGRAM_ID"

# Update lib.rs FIRST (before build)
CURRENT_LIB_ID=$(grep "declare_id!" programs/pledgr/src/lib.rs | sed 's/declare_id!("\\(.*\\)");/\1/')
if [ "$CURRENT_LIB_ID" != "$PROGRAM_ID" ]; then
  sed -i '' "s/declare_id!\(\"[^\"]*\"\)/declare_id!(\"$PROGRAM_ID\")/" programs/pledgr/src/lib.rs
  echo "Updated lib.rs: $CURRENT_LIB_ID -> $PROGRAM_ID"
fi

# Build
echo ""
echo "Building..."
cargo build-sbf

# Check if program exists
echo ""
echo "Checking program status..."
if solana program show $PROGRAM_ID >/dev/null 2>&1; then
  echo "Program exists - UPGRADING..."
  solana program deploy --skip-fee-check --skip-preflight target/deploy/pledgr.so --program-id $PROGRAM_ID
  echo "UPGRADE complete!"
else
  echo "Program does NOT exist - deploying FRESH..."
  # Check if we have the keypair
  if [ -f "target/deploy/pledgr-keypair.json" ]; then
    solana program deploy --skip-fee-check --skip-preflight target/deploy/pledgr.so --program-id $PROGRAM_ID
    echo "FRESH deploy complete!"
  else
    echo "ERROR: No keypair found for fresh deploy!"
    echo "Run: solana-keygen new -o target/deploy/pledgr-keypair.json"
    exit 1
  fi
fi

# Update Anchor.toml
sed -i '' "s/pledgr = \"[^\"]*\"/pledgr = \"$PROGRAM_ID\"/" Anchor.toml
echo "Updated Anchor.toml"

echo ""
echo "========================================="
echo "DONE!"
echo "Program ID: $PROGRAM_ID"
echo "========================================="
