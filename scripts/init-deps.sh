#!/usr/bin/env bash
# Initialise the submodules the build needs, and only those.
#
# `git submodule update --init --recursive` would also clone every nested dependency of the Euler repos
# (layerzero, euler-swap, pendle, redstone, uniswap, ...), which this repo never compiles. Only these
# nested copies are used: see the context-prefixed remappings in foundry.toml.
set -euo pipefail
cd "$(dirname "$0")/.."

git submodule update --init
git -C lib/euler-vault-kit submodule update --init lib/openzeppelin-contracts lib/permit2
git -C lib/euler-price-oracle submodule update --init lib/openzeppelin-contracts
git -C lib/evk-periphery submodule update --init lib/openzeppelin-contracts-upgradeable
