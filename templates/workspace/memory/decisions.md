# Design Decisions Log

Record important architectural decisions, trade-offs, and precedents here. This helps agents understand context and make consistent choices.

## Format

```markdown
## Decision: [Short Title]

**Date:** YYYY-MM-DD
**Context:** Why was this decision needed?
**Options Considered:**
- Option A: Pros and cons
- Option B: Pros and cons
- Option C: Pros and cons

**Decision:** Which option was chosen and why
**Trade-offs:** What was sacrificed for this choice
**Related Decisions:** Links to other decisions
**Status:** Active | Superseded | Under Review

**Implications for Agents:**
- How should agents approach similar situations?
- What patterns should be followed?
- Common pitfalls to avoid?
```

## Examples

### Decision: Use Kafka for Metrics Pipeline

**Date:** 2024-01-10
**Context:** Needed high-throughput, decoupled metrics ingestion. Original design had data collector writing directly to database.

**Options Considered:**
- Option A: Direct database writes from collectors
  - Pros: Simplest to implement
  - Cons: Database becomes bottleneck, tight coupling, hard to scale

- Option B: Use Kafka message queue
  - Pros: Decouples services, enables scalability, provides ordering guarantees, allows replay for debugging
  - Cons: Added operational complexity, new dependency

- Option C: Use Redis pub/sub
  - Pros: Lower latency than Kafka
  - Cons: No persistence, no ordering guarantees, doesn't fit high-volume use case

**Decision:** Use Kafka (Option B)
Trade-offs: Added operational complexity for unlimited scalability. Acceptable because we need to support 100k+ metrics/second.

**Implications for Agents:**
- Always use Kafka for metric streaming, not database writes
- Implement proper consumer groups for parallelism
- Handle Kafka failures gracefully (reconnect with backoff)
- Don't query metrics directly from Kafka; let them persist to database first

---

### Decision: Separate API and Alerter Services

**Date:** 2024-01-08
**Context:** Needed to evaluate thousands of alert rules in real-time while also serving API requests. A combined service would have resource contention.

**Options Considered:**
- Option A: Single service handling both API and alerting
  - Pros: Single codebase, less infrastructure
  - Cons: Resource contention, complex dependency management

- Option B: Separate services
  - Pros: Independent scaling, different resource profiles (API is I/O, Alerter is CPU)
  - Cons: More services to manage, coordination challenges

**Decision:** Separate services (Option B)
Trade-offs: More infrastructure to manage for better scalability and team independence.

**Implications for Agents:**
- Changes to alert evaluation logic go in alerter, not API
- API changes should go in API service
- When coordinating changes, deploy alerter first, then API
- Use shared types library to avoid synchronization issues

---

### Decision: PostgreSQL + Redis, Not Single NoSQL Store

**Date:** 2024-01-05
**Context:** Need to store configuration (users, dashboards, rules) AND metrics. Different query patterns and consistency requirements.

**Options Considered:**
- Option A: MongoDB for everything
  - Pros: Single database, flexible schema
  - Cons: Not optimized for time-series, slower for transactional writes

- Option B: PostgreSQL for config, TimescaleDB for metrics
  - Pros: Right tool for each job, excellent time-series support
  - Cons: More expertise needed, operational complexity

- Option C: PostgreSQL + Redis caching layer
  - Pros: Transactional consistency, fast caching for hot data
  - Cons: Cache invalidation complexity

**Decision:** PostgreSQL + Redis (Option C)
Trade-offs: Complexity of cache management for superior performance and consistency.

**Implications for Agents:**
- Configuration (users, rules) goes in PostgreSQL with transactions
- Metric cache goes in Redis with TTL
- When creating features with both config and data, be explicit about which storage
- Never rely on Redis for long-term data persistence
- Always implement cache invalidation when updating config

---

### Decision: React + Context API, Not Redux

**Date:** 2024-01-03
**Context:** Need state management for authentication, dashboard data. Debating Redux vs Context API + custom hooks.

**Options Considered:**
- Option A: Redux
  - Pros: Mature ecosystem, devtools, predictable state management
  - Cons: Boilerplate, learning curve, overkill for current app size

- Option B: React Context + useReducer
  - Pros: Built-in, less boilerplate, sufficient for current needs
  - Cons: Limited devtools, not as optimized for large stores

**Decision:** Context API + custom hooks (Option B)
Trade-offs: May need to migrate to Redux if app grows significantly. Currently not a concern.

**Implications for Agents:**
- Use Context API for state management
- Create custom hooks for specific features (useAuth, useMetrics)
- Avoid prop drilling with context
- Keep context providers at appropriate nesting level
- If you feel needing Redux features, update this decision first

---

### Decision: TypeScript Strict Mode

**Date:** 2023-12-28
**Context:** Wanted to catch as many errors at compile time as possible, reduce runtime surprises.

**Options Considered:**
- Option A: JavaScript (no types)
  - Pros: Faster initial development
  - Cons: More runtime errors, harder to refactor

- Option B: TypeScript with relaxed settings
  - Pros: Some type safety without strictness
  - Cons: Still allows `any` types, less safe

- Option C: TypeScript strict mode
  - Pros: Maximum safety, self-documenting code, easy refactoring
  - Cons: Slower initial development, more verbose

**Decision:** TypeScript strict mode (Option C)
Trade-offs: Slower initial development for significantly better maintainability and fewer bugs.

**Implications for Agents:**
- All new files MUST be TypeScript with strict mode
- Never use `any` types; use specific types instead
- Always provide explicit return types for functions
- Type generic constraints properly
- No `// @ts-ignore` without documented justification

---

## Under Review / To Decide

### Consideration: Move to Deno for Backend Services

**Status:** Under Review
**Context:** Evaluating if Deno's security model and TypeScript-first approach would improve development experience.
**Next Steps:** Evaluate with small service first, measure developer productivity impact

### Consideration: Migrate to Svelte for Frontend

**Status:** Under Review
**Context:** Assessing if Svelte's simpler component model would reduce bundle size and improve performance.
**Next Steps:** Spike on refactoring one complex component to Svelte

---

## Superseded Decisions

### Decision: Use Direct Database Connections (Superseded 2024-01-10)

**Previous Decision:** All services connect directly to PostgreSQL
**Superseded By:** Use Kafka for metrics pipeline (2024-01-10)
**Reason:** Database became bottleneck with high metric volume, Kafka provides better scaling

### Decision: Store All Data in PostgreSQL (Superseded 2024-01-05)

**Previous Decision:** Use PostgreSQL for everything including metrics
**Superseded By:** PostgreSQL + Redis hybrid (2024-01-05)
**Reason:** Time-series queries too slow, Redis caching essential for real-time performance

---

## When Agents Encounter New Decisions

If working on something not covered by existing decisions:

1. **Document the decision** when choosing between options
2. **Include trade-offs** so future agents understand the reasoning
3. **Note implications** for consistency
4. **Update this file** before committing code
5. **Reference in commit message**: `docs(decisions): add decision for X`

Example commit:
```
docs(decisions): add decision for API versioning strategy

Added decision doc explaining why we chose header-based versioning
over URL-based versioning. Includes trade-offs and implications
for API design going forward.

Resolves: #123
```

---

## Decision Timeline

- 2024-01-10: Use Kafka for metrics pipeline
- 2024-01-08: Separate API and Alerter services
- 2024-01-05: PostgreSQL + Redis, not single NoSQL
- 2024-01-03: React Context API, not Redux
- 2023-12-28: TypeScript strict mode
