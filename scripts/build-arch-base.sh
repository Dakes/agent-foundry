#!/usr/bin/env bash
#
# Agent Foundry - Build Arch Linux Base Template
#
# Creates minimal Arch Linux base template for VMs
#

set -euo pipefail

echo "Building Arch Linux Base Template"
echo "=================================="
echo ""
echo "TODO: Implement base template builder"
echo ""
echo "This script should:"
echo "- Create disk image with qemu-img"
echo "- Format as ext4"
echo "- Mount loopback"
echo "- Run pacstrap with base packages"
echo "- Configure systemd-networkd"
echo "- Enable sshd"
echo "- Configure SSH authorized_keys"
echo "- Disable root password"
echo "- Set timezone/locale"
echo "- Unmount and finalize"
echo ""
echo "See TODO.md Phase 3 for details"
exit 1
