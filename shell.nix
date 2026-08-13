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

    # Sandboxes
    docker            # Docker Sandboxes runs on the docker daemon

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
    echo "  • sbx: $(sbx version 2>&1 | head -n1 || echo 'not installed')"
    echo "  • docker: $(docker --version 2>&1 | head -n1)"
    echo "  • jq: $(jq --version)"
    echo ""
    echo "Quick start:"
    echo "  ./install.sh          Install framework to /usr/local/bin"
    echo "  foundry doctor --fix  Check the host and apply the policy baseline"
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
