# Example TypeScript Project - Bug Fixes

> **Instructions**: Complete these 3 tasks to improve code quality. Check off as completed.

## Task 1: Fix Async Error Handling

- [ ] **Add proper error handling in API client** (`src/api/client.ts:45-50`)
  - Current: `fetch()` calls don't handle network errors
  - Fix: Add try/catch with proper error types
  - Return typed error objects instead of throwing raw errors
  - Add unit tests for error cases

## Task 2: Add TypeScript Strict Mode

- [ ] **Enable strict mode in tsconfig.json**
  - Set `"strict": true` in compiler options
  - Fix any type errors that surface (expected: ~5-10 errors)
  - Add missing type annotations to function parameters
  - Ensure all return types are explicit

## Task 3: Improve Component Props Types

- [ ] **Add proper types to UserCard component** (`src/components/UserCard.tsx`)
  - Define `UserCardProps` interface
  - Add PropTypes validation
  - Make optional props explicit with `?` syntax
  - Add JSDoc comments for complex props

---

## Completion

When all 3 tasks are done:
- [ ] Run tests: `npm test`
- [ ] Check types: `npm run type-check`
- [ ] Lint: `npm run lint`
- [ ] Build: `npm run build`

Then signal completion with:
```
RALPH_STATUS {
  "EXIT_SIGNAL": true,
  "reason": "All TypeScript improvements completed",
  "completion_summary": "Fixed error handling, enabled strict mode, added proper types"
}
```
