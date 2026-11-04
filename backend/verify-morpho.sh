#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../contracts"
forge build >/dev/null
dep=deployments/143-morpho.json
get() { jq -r ".$1" "$dep"; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

verify() {
  local addr=$1 name=$2 args=${3#0x}
  local file=${name%%:*} contract=${name##*:}
  forge verify-contract "$addr" "$name" --chain 143 --show-standard-json-input > "$tmp/input.json"
  jq .metadata "out/$(basename "$file")/$contract.json" > "$tmp/metadata.json"
  echo "verifying $name at $addr"
  jq -n --arg addr "$addr" --arg name "$name" --arg args "$args" \
    --slurpfile input "$tmp/input.json" --slurpfile meta "$tmp/metadata.json" \
    '{chainId: 143, contractAddress: $addr, contractName: $name,
      compilerVersion: ("v" + $meta[0].compiler.version),
      standardJsonInput: $input[0], foundryMetadata: $meta[0], constructorArgs: $args}' |
    curl -sS -X POST https://agents.devnads.com/v1/verify -H "Content-Type: application/json" -d @-
  echo
}

usdc=$(get usdc) nvda=$(get nvda) oracle=$(get oracle) irm=$(get irm) lltv=$(get lltv)

verify "$usdc" src/Token.sol:Token \
  "$(cast abi-encode "constructor(string,string,uint8,bool)" "Mock USDC (test)" mUSDC 6 true)"
verify "$nvda" src/Token.sol:Token \
  "$(cast abi-encode "constructor(string,string,uint8,bool)" "Mock NVIDIA (test)" mNVDA 18 true)"
verify "$oracle" src/MockMorphoOracle.sol:MockMorphoOracle \
  "$(cast abi-encode "constructor(uint256)" 200000000)"
verify "$(get router)" src/MorphoCreditRouter.sol:MorphoCreditRouter \
  "$(cast abi-encode "constructor(address,(address,address,address,address,uint256),uint64)" \
    "$(get morpho)" "($usdc,$nvda,$oracle,$irm,$lltv)" "$(get minLoanAge)")"
