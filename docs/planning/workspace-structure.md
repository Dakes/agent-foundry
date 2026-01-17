# Workspace Structure Design

## Concept

A **workspace** is a self-contained project environment in the VM containing:
- Git repositories (one or many)
- AI agent context files
- Agent memory/state
- Custom instructions

## Directory Layout

```
/work/<project-name>/
├── repos/                      # Git repositories
│   ├── backend/               # Example: backend repo
│   ├── frontend/              # Example: frontend repo
│   └── infrastructure/        # Example: infra repo
├── context/                   # AI agent context
│   ├── company.md            # Company/product description
│   ├── instructions.md       # Agent behavior instructions
│   ├── coding-standards.md   # Coding style guide
│   └── architecture.md       # System architecture docs
├── memory/                    # Agent memory (read/write)
│   ├── decisions.md          # Design decisions made
│   ├── progress.md           # Work progress tracking
│   ├── blockers.md           # Current blockers/issues
│   └── learnings.md          # Patterns learned
├── skills/                    # Custom skills (not tracked in agent-foundry)
│   └── .gitkeep
├── workspace.json            # Workspace configuration
└── README.md                 # Workspace overview
```

## workspace.json Schema

```json
{
  "name": "my-project",
  "description": "Full-stack web application",
  "repositories": [
    {
      "name": "backend",
      "url": "git@github.com:user/backend.git",
      "branch": "main"
    },
    {
      "name": "frontend",
      "url": "git@github.com:user/frontend.git",
      "branch": "main"
    }
  ],
  "agent": {
    "default_cli": "claude",
    "model": "claude-sonnet-4.5",
    "context_files": [
      "context/company.md",
      "context/instructions.md"
    ],
    "memory_files": [
      "memory/progress.md"
    ]
  },
  "vm": {
    "cpus": null,  // null = use default (50% of host)
    "memory_mb": 8192,
    "disk_gb": 20
  }
}
```

## Benefits

1. **Portable** - Entire project context in one directory
2. **Multi-repo support** - Handle complex projects naturally
3. **Rich context** - Agents know company/product/architecture
4. **Persistent memory** - Agents remember across sessions
5. **Customizable** - Per-project instructions and skills
6. **Git-friendly** - Repos are standard git checkouts

## Workflow

1. User creates workspace config on host
2. Framework provisions VM with workspace structure
3. Clones specified repositories
4. Copies context files into workspace
5. Initializes memory files
6. Agent starts with full context loaded
7. Agent can read/write memory files during work
8. Agent commits to repo branches as usual

## Context Injection

Agents will have access to workspace context via:
- Environment variables pointing to context files
- Startup scripts that display context summary
- Agent loop can read context files as needed
- Memory files updated after each work session
