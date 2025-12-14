#!/bin/bash

echo "=== Building svd2odin code generator ==="
cd svd2odin
odin build src -out:bin/svd2odin || { echo "Build failed!"; exit 1; }
cd ..

echo ""
echo "=== Generating STM32F3 peripheral code ==="
# Note: svd2odin has a memory cleanup bug but generates files correctly
# Run from svd2odin directory so it can find driver_templates
cd svd2odin
./bin/svd2odin ../STM32F303.svd ../src/stm32f3 2>&1 | grep -v "free():" || true
cd ..

echo ""
echo "=== Generation complete ==="
echo "Generated files:"
echo "  - src/stm32f3/STM32F303.ld (linker script)"
echo "  - src/stm32f3/startup_stm32f303.s (startup assembly)"
echo "  - src/stm32f3/*.odin (67 peripheral files)"
echo "  - src/stm32f3/hal/register.odin (HAL)"
echo "  - src/stm32f3/interrupts.odin (76 interrupts)"
echo "  - src/stm32f3/spi/driver.odin"
echo "  - src/stm32f3/uart/driver.odin"
echo "  - src/stm32f3/dma/driver.odin"
echo "  - src/stm32f3/i2c/driver.odin"
echo "  - src/stm32f3/debug/driver.odin"
echo "  - src/stm32f3/freestanding/driver.odin (runtime hooks)"
echo ""
echo "Ready to build firmware with: ./build.sh"
