---
name: mao-optimize
description: 效能優化。量測優先。效能問題、響應慢、記憶體/電量消耗時使用。
---

# Performance Optimization

## Core Rule

**Don't optimize without measurement evidence.** Intuition about bottlenecks is wrong more often than right.

## When NOT to Use
- No measured performance problem exists
- The code is correct but "feels slow" without data
- Premature optimization during initial development

## Workflow

### 1. Measure
Establish baseline metrics before any changes:
- Response time / frame rate
- Memory usage
- CPU / battery consumption
- Identify the specific bottleneck (profile, don't guess)

### 2. Identify
Locate the actual bottleneck — it's usually not where you think.

**Common Bottleneck Patterns:**

| Pattern | Symptom | Fix |
|---------|---------|-----|
| N+1 queries | Latency scales with data size | Batch queries, eager loading |
| Unbounded fetch | OOM or timeout on large datasets | Pagination, streaming |
| Missing cache | Same expensive computation repeated | Cache with TTL |
| Synchronous I/O | Thread blocked, UI frozen | Async / background thread |
| Unnecessary allocation | GC pressure in hot paths | Object pooling, reuse buffers |
| Over-logging | I/O bottleneck from verbose logs | Throttle, conditional logging |
| Lock contention | Threads waiting on shared resource | Reduce critical section, lock-free |

### 3. Fix
Apply the minimum change that addresses the measured bottleneck.
- One optimization at a time
- Keep the original code path testable
- Document WHY this optimization exists (so someone doesn't "clean it up" later)

### 4. Verify
Measure again with the same methodology:
- Did the metric improve?
- By how much? (quantify)
- Any regressions in other metrics?

### 5. Guard
Add a performance test or assertion to prevent regression:
- Benchmark for critical paths
- Memory limit assertions
- Timeout thresholds

## Performance Budget

Define acceptable limits for your context:
- API response: < 200ms p95
- UI frame: < 16ms (60fps) or < 33ms (30fps)
- App startup: < 2s cold start
- Memory: within device class constraints

## Red Flags
- Optimizing without profiling data
- "This might be slow" without measurement
- Optimizing code that runs once (startup config, etc.)
- Adding complexity for unmeasured theoretical gains
- Caching without invalidation strategy
