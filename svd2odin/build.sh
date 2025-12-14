#!/bin/bash
# Build svd2odin code generator

set -e

ODIN_PATH="/home/kalsprite/dev/odin"

echo "Building svd2odin..."
${ODIN_PATH}/odin build src -out:svd2odin -o:speed

echo "Build complete: ./svd2odin"
