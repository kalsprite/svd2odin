#!/bin/bash
set -e

echo "=== Building STM32 Firmware ==="
./build.sh

echo ""
echo "=== Flashing to board ==="
st-flash write build/firmware.bin 0x08000000
echo "=== Flash Complete ==="
#echo ""
#echo "=== Connecting to serial output ==="
#echo "Press Ctrl+A then Ctrl+X to exit picocom"
#echo ""
#sleep 1

#picocom -b 115200 /dev/ttyACM0
