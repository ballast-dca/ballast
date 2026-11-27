#!/usr/bin/env bash
# Deploy Ballast: BallastBrain on Reactive mainnet, BallastExecutor and MarketMood on Base, link and seed.
#   ACCOUNT=steady WEEKLY_USDC=10 bash script/deploy.sh
# Funding (USDC into the executor) is a separate, explicit step; see README.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"

ACCOUNT=${ACCOUNT:-steady}
SIGN=(--account "$ACCOUNT" --password-file "$HOME/.foundry/$ACCOUNT.pass")
BASE_RPC=${BASE_RPC:-https://mainnet.base.org}
REACTIVE_RPC=${REACTIVE_RPC:-https://mainnet-rpc.rnk.dev/}
BASE_ID=8453
FEED=0xe5ec87a39445b8D5b751b116802A53C5ae7e9Df1        # Chainlink BTC/USD aggregator on Base (emits AnswerUpdated)
PROXY=0xCc780DdE33f56f55dE778D42c930959374a4a068       # Reactive callback proxy on Base
SYSTEM=0x8888888888888888888888888888888888888888
INTERVAL=${INTERVAL:-604800}                            # one week
WEEKLY=$(( ${WEEKLY_USDC:-10} * 1000000 ))
BRAIN_FUND=${BRAIN_FUND:-10ether}                       # REACT kept by the brain for reactions
BRAIN_RESERVE=${BRAIN_RESERVE:-5ether}                  # REACT deposited as system reserves
EXEC_FUND=${EXEC_FUND:-0.0001ether}                     # ETH for callback fees on Base

addr() { grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }

forge build

BRAIN=$(forge create src/BallastBrain.sol:BallastBrain --broadcast --rpc-url "$REACTIVE_RPC" --chain-id 1597 \
  "${SIGN[@]}" --value "$BRAIN_FUND" --constructor-args $BASE_ID $FEED $INTERVAL | addr)
echo "BallastBrain (Reactive mainnet): $BRAIN"

EXEC=$(forge create src/BallastExecutor.sol:BallastExecutor --broadcast --rpc-url "$BASE_RPC" \
  "${SIGN[@]}" --value "$EXEC_FUND" --constructor-args $PROXY "$BRAIN" $WEEKLY | addr)
echo "BallastExecutor (Base): $EXEC"

MOOD=$(forge create src/MarketMood.sol:MarketMood --broadcast --rpc-url "$BASE_RPC"   "${SIGN[@]}" --value "$EXEC_FUND" --constructor-args $PROXY "$BRAIN" | addr)
echo "MarketMood (Base): $MOOD"

cast send "$BRAIN" "setTargets(address,address)" "$EXEC" "$MOOD" --rpc-url "$REACTIVE_RPC" "${SIGN[@]}" > /dev/null
SEED=$(python script/seed.py | tee /dev/stderr | grep SEED_ARGS | cut -d= -f2)
# shellcheck disable=SC2086
cast send "$BRAIN" "seed(uint256,uint256,uint256,uint256,uint256,uint256)" $SEED \
  --rpc-url "$REACTIVE_RPC" "${SIGN[@]}" > /dev/null
cast send $SYSTEM "depositTo(address)" "$BRAIN" --value "$BRAIN_RESERVE" --rpc-url "$REACTIVE_RPC" "${SIGN[@]}" > /dev/null
cast send $PROXY "depositTo(address)" "$EXEC" --value 0.00005ether --rpc-url "$BASE_RPC" "${SIGN[@]}" > /dev/null
cast send $PROXY "depositTo(address)" "$MOOD" --value 0.00005ether --rpc-url "$BASE_RPC" "${SIGN[@]}" > /dev/null

cat > deployments.env <<EOF
BRAIN=$BRAIN
EXECUTOR=$EXEC
MOOD=$MOOD
EOF
echo "linked, seeded, funded; saved deployments.env"
echo "Next: send USDC to the executor: cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 'transfer(address,uint256)' $EXEC <amount 6dp> ..."
