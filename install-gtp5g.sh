#!/bin/bash
# Install gtp5g kernel module (required for UPF)
# Compatible with free5GC v4.2.0
set -e

echo "=== Installing gtp5g kernel module v0.9.5 ==="

# Prerequisites
apt-get update && apt-get install -y build-essential linux-headers-$(uname -r) git

# Clone and build
cd /tmp
rm -rf gtp5g
git clone -b v0.9.5 https://github.com/free5gc/gtp5g.git
cd gtp5g
make clean && make && make install

# Load module
modprobe gtp5g

# Verify
if lsmod | grep -q gtp5g; then
    echo "=== gtp5g installed and loaded ==="
    lsmod | grep gtp5g
else
    echo "=== FAILED: gtp5g not loaded ==="
    exit 1
fi
