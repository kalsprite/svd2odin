#!/bin/bash
# Regenerate all STM32 code from SVD and board.json

set -e

echo "=== Rebuilding svd2odin ==="
cd svd2odin
./build.sh
cd ..

echo ""
echo "=== Cleaning old generated code ==="
rm -rf src/stm32

echo ""
echo "=== Generating new code ==="
./svd2odin/svd2odin board.yaml src/stm32

echo ""
echo "=== Code generation complete ==="
echo "Generated code is in src/stm32/"
echo "Board-specific code is in src/stm32/board/"
