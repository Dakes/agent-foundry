# Patterns & Learnings

Cumulative knowledge about what works well in this project. Updated as agents discover patterns, anti-patterns, and best practices.

## Patterns That Work Well

### Pattern: Shared Types Library First

**Context:** When starting feature work across multiple services

**Pattern:**
1. Define types in `repos/shared/types/`
2. Create Zod validation schemas alongside types
3. Export types for use in all services
4. Update services after types are solid

**Why It Works:**
- Prevents API mismatches between frontend and backend
- Zod ensures runtime validation (catch bugs early)
- Services stay in sync naturally
- Code review is cleaner (types reviewed first)

**Example:**
```typescript
// repos/shared/types/dashboard.types.ts
export interface Dashboard {
  id: string;
  name: string;
  config: DashboardConfig;
  organizationId: string;
  createdBy: string;
  createdAt: Date;
  updatedAt: Date;
}

// repos/shared/types/dashboard.schemas.ts
export const DashboardSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1).max(255),
  config: z.any(), // or specific schema
  organizationId: z.string().uuid(),
  createdBy: z.string().uuid(),
  createdAt: z.date(),
  updatedAt: z.date(),
});
```

**Agent Action:** When building new features, always define types first.

---

### Pattern: Database Migrations Before Queries

**Context:** When implementing database features

**Pattern:**
1. Write migration SQL file in `migrations/`
2. Run migration against test database
3. Update TypeScript models to match schema
4. Write queries with TypeScript types
5. Test with real schema

**Why It Works:**
- Migrations are version-controlled and reversible
- TypeScript types match actual database schema
- No surprises in production
- Easy to review schema changes

**Example Migration:**
```sql
-- 006_add_webhook_columns_to_alert_rules.sql
ALTER TABLE alert_rules ADD COLUMN webhook_url VARCHAR(2000);
ALTER TABLE alert_rules ADD COLUMN webhook_retries SMALLINT DEFAULT 3;
ALTER TABLE alert_rules ADD CONSTRAINT check_webhook_retries
  CHECK (webhook_retries >= 0 AND webhook_retries <= 10);
```

**Agent Action:** Never create tables or modify schema in code - use migrations.

---

### Pattern: Error Types Over Generic Errors

**Context:** When implementing error handling

**Pattern:**
Create specific Error classes:
```typescript
export class ValidationError extends Error {
  constructor(message: string, public field: string) {
    super(message);
    this.name = 'ValidationError';
  }
}

export class NotFoundError extends Error {
  constructor(resource: string, id: string) {
    super(`${resource} not found: ${id}`);
    this.name = 'NotFoundError';
  }
}

export class UnauthorizedError extends Error {
  constructor(message: string = 'Unauthorized') {
    super(message);
    this.name = 'UnauthorizedError';
  }
}
```

Then handle specifically:
```typescript
try {
  const user = await getUserById(id);
  if (!user) throw new NotFoundError('User', id);
} catch (error) {
  if (error instanceof NotFoundError) {
    res.status(404).json({ error: error.message });
  } else if (error instanceof UnauthorizedError) {
    res.status(401).json({ error: error.message });
  } else {
    logger.error('Unexpected error', error);
    res.status(500).json({ error: 'Internal server error' });
  }
}
```

**Why It Works:**
- Code intention is clear
- Handlers match error types
- Stack traces preserve context
- Easy to test error paths

**Agent Action:** Create specific Error types for each domain (Auth, Validation, Database, etc.)

---

### Pattern: Database Indexing Early

**Context:** When designing database tables

**Pattern:**
Add indexes at table creation time for:
- Primary keys (automatic)
- Foreign keys (for joins)
- Frequently filtered columns
- Frequently sorted columns
- Unique constraints

**Example:**
```sql
CREATE TABLE users (
  id UUID PRIMARY KEY,
  email VARCHAR(255) UNIQUE NOT NULL,
  organization_id UUID NOT NULL REFERENCES organizations(id),
  created_at TIMESTAMP DEFAULT NOW(),

  -- Indexes for common queries
  INDEX idx_users_org (organization_id),
  INDEX idx_users_email_org (email, organization_id)
);
```

**Why It Works:**
- Prevents performance regressions later
- Easier to index during migration than in production
- Avoids costly table scans

**Agent Action:** Always index foreign keys and frequently filtered columns.

---

### Pattern: Testing Pyramid

**Context:** When writing tests

**Pattern:**
```
       UI Tests (few)
           ▲
          ╱ ╲
         ╱   ╲
   Integration Tests (some)
       ▲
      ╱ ╲
     ╱   ╲
  Unit Tests (many)
```

Breakdown:
- **Unit Tests** (70%): Single function, mocked dependencies
- **Integration Tests** (25%): Multiple components, real databases
- **E2E/UI Tests** (5%): User workflows, browsers

**Why It Works:**
- Unit tests run fast (quick feedback)
- Integration tests catch real issues
- UI tests verify end-user experience
- Pyramid is economical and practical

**Agent Action:** Write mostly unit tests, some integration tests, minimal UI tests.

---

### Pattern: Conventional Commits for Clear History

**Context:** When committing code

**Pattern:**
```
feat(scope): description
fix(scope): description
docs(scope): description
test(scope): description
refactor(scope): description

Examples:
feat(api): add pagination to users endpoint
fix(auth): prevent token refresh bypass
docs(decisions): add decision for Kafka choice
test(alerter): add rule evaluation tests
refactor(frontend): extract metric panel component
```

**Why It Works:**
- Easy to scan commit history
- Automated changelog generation possible
- Clear what changed and why
- Helps with searching history

**Agent Action:** Always use conventional commits.

---

## Anti-Patterns to Avoid

### Anti-Pattern: Tight Coupling Between Services

**Problem:** API service directly queries metrics from database, Alerter does same

**Why It's Bad:**
- Database becomes bottleneck
- Hard to optimize separately
- Services can't scale independently
- Difficult to test in isolation

**Better Approach:**
- Alerter reads from Kafka stream
- Database is cache/store, not primary interface
- Services decouple via message queue

---

### Anti-Pattern: Big Commits with Multiple Changes

**Problem:** One commit changes auth, database, frontend, and documentation

**Why It's Bad:**
- Hard to review
- Difficult to revert part of commit
- History is unclear
- Bisecting fails (can't isolate issue)

**Better Approach:**
- Separate commits per concern
- Each commit should be independently valuable
- Example:
  ```
  feat(shared): add User and AuthToken types
  feat(api): implement login endpoint
  feat(frontend): add login form component
  docs(architecture): document auth flow
  test(api): add auth integration tests
  ```

---

### Anti-Pattern: Magic Numbers and Strings

**Problem:**
```javascript
const response = await fetch(url);
if (response.status === 401) { // what does 401 mean?
  // logout
}
```

**Why It's Bad:**
- Not obvious what number means
- Hard to change consistently
- Harder to read

**Better Approach:**
```typescript
const HTTP_UNAUTHORIZED = 401;
const HTTP_INTERNAL_ERROR = 500;

if (response.status === HTTP_UNAUTHORIZED) {
  // logout
}
```

Or use enums/constants from libraries:
```typescript
if (response.status === HttpStatusCode.UNAUTHORIZED) {
  // logout
}
```

---

### Anti-Pattern: Conditional Logic Instead of Polymorphism

**Problem:**
```typescript
function processNotification(notification: any) {
  if (notification.type === 'email') {
    sendEmail(notification);
  } else if (notification.type === 'slack') {
    sendSlack(notification);
  } else if (notification.type === 'sms') {
    sendSMS(notification);
  }
}
```

**Why It's Bad:**
- Adding new notification type requires modifying function
- Not extensible
- Hard to test each type

**Better Approach:**
```typescript
interface Notifier {
  send(notification: Notification): Promise<void>;
}

class EmailNotifier implements Notifier {
  async send(notification: Notification) {
    // email-specific logic
  }
}

class SlackNotifier implements Notifier {
  async send(notification: Notification) {
    // slack-specific logic
  }
}

// Usage
const notifiers: Map<string, Notifier> = new Map([
  ['email', new EmailNotifier()],
  ['slack', new SlackNotifier()],
]);

function processNotification(notification: Notification) {
  const notifier = notifiers.get(notification.type);
  if (!notifier) throw new Error(`Unknown notifier: ${notification.type}`);
  return notifier.send(notification);
}
```

---

### Anti-Pattern: Async/Await Without Error Handling

**Problem:**
```typescript
async function loadUser(id: string) {
  const response = await fetch(`/api/users/${id}`);
  const user = await response.json();
  return user;
}
```

**Why It's Bad:**
- Network errors not handled
- Invalid JSON crashes silently
- No way to know what failed

**Better Approach:**
```typescript
async function loadUser(id: string): Promise<User> {
  try {
    const response = await fetch(`/api/users/${id}`);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }
    const data = await response.json();
    return UserSchema.parse(data); // Validate with Zod
  } catch (error) {
    logger.error('Failed to load user', { id, error });
    throw new Error('Failed to load user from server');
  }
}
```

---

## Performance Insights

### Database Query Performance

**Observation:** Time-series queries slow down as data volume grows.

**Insight:** Proper indexing and query structure matter more than database choice.

**Recommendation:**
- Use EXPLAIN ANALYZE to check query plans
- Ensure indexes cover WHERE and JOIN columns
- Avoid SELECT * (fetch only needed columns)
- Partition large tables by time or ID

**Benchmark:**
```sql
-- Before (2.5 seconds on 1M rows)
SELECT * FROM metrics WHERE time > NOW() - INTERVAL '1 day';

-- After (45ms on same data)
SELECT name, value, time FROM metrics
WHERE time > NOW() - INTERVAL '1 day'
AND organization_id = $1
INDEX idx_metrics_org_time;
```

---

### JavaScript/React Performance

**Observation:** Frontend sometimes sluggish with 100+ dashboard panels.

**Insight:** React re-renders matter. Memoization prevents unnecessary renders.

**Recommendation:**
- Use React.memo for expensive components
- Use useMemo for expensive calculations
- Keep context providers high in tree (or split contexts)
- Profile with Chrome DevTools before optimizing

---

### Kafka Message Processing

**Observation:** Alerter sometimes falls behind processing metrics.

**Insight:** Consumer group parallelism limited by topic partition count.

**Recommendation:**
- Create topic with multiple partitions (10+)
- Run multiple consumer instances
- Monitor consumer lag with Kafka CLI
- Adjust batch size and processing timeout

```bash
# Check consumer group lag
kafka-consumer-groups.sh --group alerter-group \
  --describe --bootstrap-server localhost:9092
```

---

## Team/Agent Learnings

### What Slows Down Feature Development

1. **Missing Type Definitions** (High impact)
   - Leads to runtime errors
   - Requires debugging/fix cycles
   - Solution: Define types first

2. **Poor Documentation** (Medium impact)
   - Agent wastes time understanding code
   - Makes decisions inconsistent
   - Solution: Document as you code

3. **Unclear Success Criteria** (Medium impact)
   - Agent doesn't know when task is done
   - Over-engineering or under-delivering
   - Solution: Define clear acceptance criteria

4. **Stale Test Data** (Low impact, high frustration)
   - Tests pass locally but fail in CI
   - Misleading failures
   - Solution: Regular test data cleanup

---

### What Speeds Up Development

1. **Good Examples in Codebase** (High impact)
   - Agent can copy patterns
   - Consistency maintained
   - Solution: Keep examples updated

2. **Comprehensive Error Messages** (High impact)
   - Identifies problems quickly
   - Reduces debugging time
   - Solution: Custom error types with context

3. **Clear Git History** (Medium impact)
   - Easy to understand evolution
   - Helps with debugging via blame/bisect
   - Solution: Conventional commits

4. **Working Dev Environment** (Medium impact)
   - No wasted time on setup
   - Smooth iteration
   - Solution: docker-compose.yml, setup scripts

---

## When to Apply Patterns

Use this decision tree:

```
Starting new feature?
├─ Yes: Start with shared types
└─ No: Go to next question

Implementing new service?
├─ Yes: Check anti-patterns first
└─ No: Go to next question

Database changes?
├─ Yes: Use migrations, add indexes
└─ No: Go to next question

Error handling needed?
├─ Yes: Create specific Error types
└─ No: Go to next question

Writing tests?
├─ Yes: Follow testing pyramid (unit > integration > E2E)
└─ No: All done!
```

---

## Suggest New Learning

Found a pattern that consistently works? Have a new anti-pattern to warn about?

1. **Document:** Write up the pattern with examples
2. **Categorize:** Is it a pattern or anti-pattern?
3. **Add context:** Why does it work? When to apply?
4. **Include decision:** Should this be mandatory, recommended, or optional?
5. **Example code:** Show good vs bad approach
6. **Commit:** `docs(learnings): add pattern for X`

Example commit:
```
docs(learnings): add pattern for error handling

Added pattern for using specific Error types instead of generic Error.
Includes examples of creating custom errors and handling them in try/catch.
Explains why polymorphic error types lead to better code.

Resolves: #456
```

---

## References

These documents are foundational:
- `context/instructions.md` - Agent behavior guidelines
- `context/coding-standards.md` - Code style requirements
- `context/architecture.md` - System design and patterns
- `memory/decisions.md` - Architectural decisions and trade-offs
