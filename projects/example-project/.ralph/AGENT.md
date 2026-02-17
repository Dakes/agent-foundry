# Example TypeScript App - Build & Run Instructions

## VM Environment

You are running as **root** in an **isolated Ubuntu 22.04 microVM** managed by Agent Foundry:

- **Root access** - You are root, install any packages: `apt-get install <package>`
- **Isolated filesystem** - Changes only affect this VM, not the host
- **Network access** - Full internet connectivity for downloading dependencies
- **Persistent storage** - Files survive across agent restarts
- **Complete control** - Modify system files, install services, change configs

**Common operations:**
```bash
# Install system packages (no sudo needed - you are root)
apt-get update
apt-get install -y postgresql redis-tools

# Install language runtimes
apt-get install -y python3.11 golang-1.20

# View system resources
df -h          # Disk space
free -h        # Memory
nproc          # CPU cores
```

**Important:** This is a microVM, not a container - you can modify anything, including system files, kernel modules, and network settings.

## System Requirements

- **Node.js**: 18+ (LTS)
- **Package Manager**: npm
- **TypeScript**: 5.0+
- **Testing**: Jest
- **Linting**: ESLint + Prettier

## Initial Setup

```bash
# Navigate to repository
cd /root/repos/my-app

# Install dependencies
npm install

# Verify setup
npm run type-check
```

## Development Workflow

```bash
# Start development server
npm run dev              # Starts on localhost:3000

# Run in watch mode
npm run dev:watch        # Auto-reloads on file changes
```

## Testing

```bash
# Run all tests
npm test

# Run tests in watch mode
npm test -- --watch

# Run with coverage
npm test -- --coverage

# Run specific test file
npm test UserCard.test.tsx
```

## Code Quality

```bash
# Type checking
npm run type-check

# Linting
npm run lint

# Fix linting issues
npm run lint:fix

# Format code
npm run format

# Run all checks (recommended before commit)
npm run check-all
```

## Building

```bash
# Production build
npm run build           # Output to dist/

# Preview production build
npm run preview         # Serves dist/ locally
```

## Project Structure

```
my-app/
├── src/
│   ├── api/           # API client code
│   ├── components/    # React components
│   ├── utils/         # Helper functions
│   └── types/         # TypeScript type definitions
├── tests/             # Test files
└── dist/              # Build output
```

## Common Commands

| Command | Purpose |
|---------|---------|
| `npm install` | Install dependencies |
| `npm run dev` | Start dev server |
| `npm test` | Run tests |
| `npm run type-check` | Check TypeScript types |
| `npm run lint` | Lint code |
| `npm run build` | Production build |

## Troubleshooting

**"Module not found"**
```bash
npm install  # Reinstall dependencies
```

**"Type errors after changes"**
```bash
npm run type-check  # See specific errors
```

**"Tests failing"**
```bash
npm test -- --verbose  # See detailed output
```
