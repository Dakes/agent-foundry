{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "agent-foundry-dev";

  buildInputs = with pkgs; [
    # Core tools
    bash
    git
    curl
    wget
    jq

    # VM and networking
    qemu-utils        # For qemu-img
    firecracker       # VM hypervisor
    iproute2          # For ip commands
    iptables          # For NAT

    # Session management
    tmux
    screen

    # SSH
    openssh

    # Development
    shellcheck        # Shell script linting
    shfmt             # Shell script formatting

    # Optional but useful
    htop
    ncdu
  ];

  shellHook = ''
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          Agent Foundry Development Environment          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Available tools:"
    echo "  • firecracker: $(firecracker --version 2>&1 | head -n1)"
    echo "  • qemu-img: $(qemu-img --version | head -n1)"
    echo "  • jq: $(jq --version)"
    echo ""
    echo "Quick start:"
    echo "  ./install.sh          Install framework to /usr/local/bin"
    echo "  foundry host setup    Configure host system"
    echo "  foundry --help        Show available commands"
    echo ""
    echo "Documentation:"
    echo "  docs/VISION.md        Project vision and goals"
    echo "  docs/ARCHITECTURE.md  Architecture overview"
    echo "  docs/CLI-REFERENCE.md Command reference"
    echo "  TODO.md               Implementation roadmap"
    echo ""
  '';
}
