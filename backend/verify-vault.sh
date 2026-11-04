#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../contracts"
forge build >/dev/null
chain=10143
rpc=${RPC_URL:-https://testnet-rpc.monad.xyz}
dep=deployments/$chain.json
get() { jq -r ".$1" "$dep"; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

verify() {
  local addr=$1 name=$2 args=${3#0x}
  local file=${name%%:*} contract=${name##*:}
  forge verify-contract "$addr" "$name" --chain "$chain" --show-standard-json-input > "$tmp/input.json"
  jq .metadata "out/$(basename "$file")/$contract.json" > "$tmp/metadata.json"
  echo "verifying $name at $addr"
  jq -n --argjson chain "$chain" --arg addr "$addr" --arg name "$name" --arg args "$args" \
    --slurpfile input "$tmp/input.json" --slurpfile meta "$tmp/metadata.json" \
    '{chainId: $chain, contractAddress: $addr, contractName: $name,
      compilerVersion: ("v" + $meta[0].compiler.version),
      standardJsonInput: $input[0], foundryMetadata: $meta[0]}
      + (if $args == "" then {} else {constructorArgs: $args} end)' |
    curl -sS -X POST https://agents.devnads.com/v1/verify -H "Content-Type: application/json" -d @-
  echo
}

token() {
  local args
  args=$(cast abi-encode "constructor(string,string,uint8,bool)" "$2" "$3" "$4" "$5")
  verify "$1" src/Token.sol:Token "$args"
}

usdc=$(get usdc)
# the open mint flag changed between deploys, so read it from the chain
open=$(cast call "$usdc" "openMint()(bool)" --rpc-url "$rpc")

token "$usdc" "Mock USDC" mUSDC 6 "$open"
token "$(get mNVDA)" "Mock NVIDIA" mNVDA 18 true
token "$(get mTSLA)" "Mock Tesla" mTSLA 18 true
token "$(get mAAPL)" "Mock Apple" mAAPL 18 true
verify "$(get vault)" src/Vault.sol:Vault \
  "$(cast abi-encode "constructor(address,uint64)" "$usdc" "$(get minLoanAge)")"

if [ "$(get mocks)" = true ]; then
  verify "$(get identity)" src/mocks/MockIdentityRegistry.sol:MockIdentityRegistry ""
  verify "$(get reputation)" src/mocks/MockReputationRegistry.sol:MockReputationRegistry ""
fi
