# Blockers & Issues Log

Track obstacles, bugs, environmental issues, and problems that need human intervention.

## Format

```markdown
## Blocker: [Title]

**ID:** [blocker-001]
**Date Found:** YYYY-MM-DD
**Severity:** Critical | High | Medium | Low
**Status:** Active | In Progress | Resolved | Deferred

**Description:** What's the problem?
**Root Cause:** Why is this happening?
**Impact:** What work is blocked?
**Reproduction Steps:** How to reproduce?
**Attempted Solutions:** What have we tried?

**Resolution:** How was it fixed? (filled in when resolved)
**Lessons:** What did we learn?
```

## Active Blockers

Currently none! System is operating smoothly.

---

## Resolved Blockers

### Blocker: TypeScript Compilation Error in Alert Rules

**ID:** blocker-001
**Date Found:** 2024-01-16
**Severity:** High
**Status:** Resolved

**Description:**
TypeScript strict mode compilation failing in alert rule types.
Error: `Type 'string | number' is not assignable to type 'string'`

**Root Cause:**
AlertRule interface was using union types for `threshold` field (from old design).
Strict mode requires explicit type narrowing.

**Impact:**
- Could not compile alerter service
- Blocked deployment of alert evaluation feature

**Reproduction:**
```bash
cd repos/backend/alerter
npm run build
# Error in src/types/AlertRule.ts:12:5
```

**Attempted Solutions:**
1. First tried type assertion with `as string` (wrong - masked problem)
2. Added `// @ts-ignore` (not allowed in strict mode)
3. Finally fixed the root cause

**Resolution:**
Changed AlertRule interface:
```typescript
// Before
interface AlertRule {
  threshold: string | number;  // ❌ Union type
}

// After
interface AlertRule {
  threshold: number;            // ✅ Explicit type
  severity: 'critical' | 'warning' | 'info';
}
```

Also updated validation schema to enforce numeric threshold.

**Lessons:**
- Union types cause trouble in strict mode; prefer explicit types
- Type assertions hide problems; fix root cause instead
- Validation schema should match TypeScript types exactly

---

### Blocker: Database Port Already in Use

**ID:** blocker-002
**Date Found:** 2024-01-15
**Severity:** High
**Status:** Resolved

**Description:**
PostgreSQL failed to start in Docker container - port 5432 already in use.

**Root Cause:**
Previous development session had left a PostgreSQL container running.

**Impact:**
- Could not start clean database
- Blocked database migration testing

**Reproduction:**
```bash
docker-compose up -d postgres
# Error: port 5432 in use
```

**Attempted Solutions:**
1. Changed docker-compose port mapping to 5433 (workaround)
2. Checked running containers: `docker ps`
3. Found old container and removed it

**Resolution:**
```bash
docker ps | grep postgres
docker rm old-postgres-container
docker-compose up -d postgres
# Success
```

**Lessons:**
- Always clean up containers between sessions
- Add cleanup script to dev environment setup
- Consider using volumes for data persistence

---

## Deferred Issues

These are real issues but not blockers right now. Revisit later.

### Issue: JWT Token Expiration Strategy

**ID:** deferred-001
**Priority:** Medium
**Context:**
JWT tokens are hardcoded to 24-hour expiration. This works but lacks flexibility.

**Discussion Points:**
- Should expiration be configurable?
- Should refresh tokens have different TTL?
- Need sliding window token refresh?

**When to Revisit:**
When implementing multi-tenant support or SSO integrations.

---

### Issue: Database Query Performance Optimization

**ID:** deferred-002
**Priority:** Low
**Context:**
Metrics queries may slow down as data volume grows. Not a problem now.

**Known Limitations:**
- Time-series partitioning is basic (by day)
- No columnar compression for old data
- Index strategy could be more sophisticated

**When to Revisit:**
When metric volume exceeds 1M events/day.

**Potential Solutions:**
- Move to TimescaleDB for better time-series support
- Implement data compression for archived metrics
- Add more sophisticated indexes

---

### Issue: Error Handling Consistency

**ID:** deferred-003
**Priority:** Low
**Context:**
Different services use different error handling patterns.

**Observations:**
- API service uses custom Error classes
- Alerter uses Error objects
- Collector uses try-catch patterns

**When to Revisit:**
When implementing centralized error logging/monitoring.

**Potential Solution:**
Create shared error handling library with standardized Error types.

---

## Troubleshooting Guide

If you encounter a problem, check here first. Add solutions as you discover them.

### "Cannot find module '@/services'"

**Symptoms:** Build fails with module not found error

**Cause:** TypeScript path aliases not properly configured

**Solution:**
```bash
# Check tsconfig.json has paths configured
cat tsconfig.json | grep -A5 '"paths"'

# If missing, add:
"paths": {
  "@/*": ["./src/*"]
}

# Rebuild
npm run build
```

---

### "Port 3000 already in use"

**Symptoms:** Dev server fails to start on port 3000

**Cause:** Another process using the port

**Solution:**
```bash
# Find process using port 3000
lsof -i :3000

# Kill it
kill -9 <PID>

# Or use a different port
PORT=3001 npm run dev
```

---

### "ECONNREFUSED: Connection refused (PostgreSQL)"

**Symptoms:** Cannot connect to database

**Cause:** PostgreSQL container not running or wrong connection params

**Solution:**
```bash
# Check if container running
docker ps | grep postgres

# If not, start it
docker-compose up -d postgres

# Wait 10 seconds for it to be ready
sleep 10

# Test connection
psql postgresql://user:password@localhost:5432/cloudash -c "SELECT 1;"
```

---

### "ExecError: Kafka broker not available"

**Symptoms:** Data collector fails to connect to Kafka

**Cause:** Kafka service not running or misconfig

**Solution:**
```bash
# Start Kafka
docker-compose up -d kafka zookeeper

# Wait 15 seconds for Kafka to be ready
sleep 15

# Test connection
kafka-topics.sh --list --bootstrap-server localhost:9092
```

---

### "Redis: ECONNREFUSED"

**Symptoms:** Services cannot connect to Redis cache

**Cause:** Redis container not running

**Solution:**
```bash
# Start Redis
docker-compose up -d redis

# Test connection
redis-cli ping
# Should return: PONG
```

---

## Reporting New Blockers

When you encounter a blocking issue:

1. **Document immediately** - Don't wait until end of session
2. **Include details:**
   - What are you trying to do?
   - What error did you see?
   - What have you already tried?
   - What's blocked by this?

3. **Attempt basic troubleshooting:**
   - Check error messages carefully
   - Search codebase for similar errors
   - Check logs and debug output

4. **Update this file:**
   ```markdown
   ## Blocker: [Your issue title]

   **ID:** blocker-XXX
   **Date Found:** [TODAY]
   **Severity:** Critical | High | Medium | Low
   **Status:** Active

   **Description:** [What's wrong]
   **Impact:** [What work is blocked]
   **Reproduction Steps:** [How to reproduce]
   **Attempted Solutions:** [What you've tried]
   ```

5. **Signal for human help:**
   - If you spend 15+ minutes stuck, escalate
   - Include blocker details in commit message
   - Example: `docs(blockers): add blocker-XXX, needs human review`

---

## Blocker Statistics

| Status | Count |
|--------|-------|
| Active | 0 |
| In Progress | 0 |
| Resolved | 2 |
| Deferred | 3 |
| **Total** | **5** |

---

## Prevention Checklist

Before starting work, ensure environment is clean:

- [ ] No stray Docker containers running
- [ ] Database started and accessible
- [ ] Kafka started (if needed for your task)
- [ ] Redis started (if needed for your task)
- [ ] All dependencies installed (`npm install`)
- [ ] TypeScript builds without errors (`npm run build`)
- [ ] Tests pass (`npm test`)
- [ ] No uncommitted changes from previous session (review with `git status`)

If any of these fail, check the Troubleshooting Guide above.
