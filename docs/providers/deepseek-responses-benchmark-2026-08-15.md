# DeepSeek Responses Transport Benchmark

Date: 2026-08-15  
Holon revision: `0753e336`  
Decision: **NO-GO for changing the default route**

## Executive summary

Holon's `deepseek@responses` route passed the correctness, cache-efficiency,
and local-compaction gates in the final controlled benchmark. It did not,
however, demonstrate a stable performance or cost advantage over the existing
`deepseek@default` Anthropic Messages route.

- All 14 task runs succeeded and passed verification.
- All 741 provider rounds completed without retries, provider errors, usage
  validation errors, cache breaks, degraded compaction, or rejected truncated
  mutations.
- Responses cache-miss input remained close to the Anthropic route: `0.966x`
  for Flash and `1.029x` for Pro, both below the `1.5x` acceptance threshold.
- Responses local compaction reduced the projected retained context by about
  `50.4%`, with all 356 observed post-compaction cache warm-ups hitting.
- Flash results were mixed: Responses cost `2.8%` more and took `5.0%` longer
  overall, despite slightly lower cache-miss input.
- Pro results were consistently worse: Responses cost `18.6%` more, took
  `14.9%` longer, and processed `51.6%` more logical input.

`deepseek@responses` therefore remains an explicit opt-in route. The benchmark
supports its operational correctness, but not replacing `deepseek@default`.

## Question

The benchmark evaluated whether Holon should change the canonical DeepSeek
route from:

- `deepseek@default/*` over Anthropic Messages

to:

- `deepseek@responses/*` over the DeepSeek Responses endpoint

The decision gate required equivalent task success and output quality, stable
cache reuse, bounded full-history growth through local compaction, and a
credible latency or cost advantage.

## Protocol

The final suite used one real repository task,
`holon-1611-tool-guidance-markdown`, with:

- `deepseek-v4-flash`: 5 paired repetitions, 10 runs
- `deepseek-v4-pro`: 2 paired repetitions, 4 runs
- deterministic randomized route order with seed `20260814`
- serial runner execution
- 5-second cooldown between runs
- provider fallback disabled
- isolated branches, worktrees, artifacts, and agent identities
- the same task verification for both routes
- a fixed 2026-08-15 pricing snapshot

Each pair ran both transports. Aggregate deltas below are Responses relative
to Anthropic Messages. Logical input includes cached input; cache-miss input is
the uncached portion used for cross-transport efficiency comparisons.

## Results

### Reliability and quality

| Model tier | Anthropic | Responses | Verification |
|---|---:|---:|---|
| Flash | 5/5 succeeded | 5/5 succeeded | 10/10 passed |
| Pro | 2/2 succeeded | 2/2 succeeded | 4/4 passed |
| Total | 7/7 succeeded | 7/7 succeeded | 14/14 passed |

Across the 741 provider rounds, neither route recorded a retry or provider
error. The audit also found no usage-validation failures, scope violations,
timeouts, cache-break classifications, degraded local-compaction rounds, or
truncated mutation rejections.

### Flash aggregate

| Metric | Anthropic Messages | Responses | Responses delta |
|---|---:|---:|---:|
| Total duration | 1,918.681 s | 2,014.085 s | +5.0% |
| Provider duration | 793.551 s | 920.531 s | +16.0% |
| Logical input tokens | 10,338,997 | 11,149,093 | +7.8% |
| Cache-miss input tokens | 220,469 | 212,901 | -3.4% |
| Cache-hit ratio | 97.87% | 98.09% | +0.22 pp |
| Output tokens | 83,754 | 87,688 | +4.7% |
| Estimated cost | $0.08265 | $0.08498 | +2.8% |

Responses finished faster in three pairs and slower in two. One slow
Responses outlier outweighed the faster pairs, while the cost result remained
slightly unfavorable in aggregate. This is mixed evidence rather than a
stable route advantage.

### Pro aggregate

| Metric | Anthropic Messages | Responses | Responses delta |
|---|---:|---:|---:|
| Total duration | 972.526 s | 1,117.474 s | +14.9% |
| Provider duration | 646.382 s | 766.511 s | +18.6% |
| Logical input tokens | 3,437,443 | 5,209,737 | +51.6% |
| Cache-miss input tokens | 92,675 | 95,369 | +2.9% |
| Cache-hit ratio | 97.30% | 98.17% | +0.87 pp |
| Output tokens | 44,125 | 54,873 | +24.4% |
| Estimated cost | $0.09083 | $0.10776 | +18.6% |

Responses was slower and more expensive in both Pro pairs. Its cache-hit ratio
was higher, but the route produced more provider rounds and substantially more
logical input and output, overwhelming that cache advantage.

## Local compaction evidence

The Responses route uses complete-history requests and cannot depend on
provider-side continuation or remote compaction. Holon therefore applies a
local projection before provider lowering.

Across the final Flash and Pro runs:

- local compaction applied on 363 Responses rounds
- projected context fell from 27,449,178 to 13,614,957 estimated tokens
- retained context was reduced by approximately 50.4%
- 2,642 tool results were compacted
- 356 post-compaction cache warm-ups were observed
- all 356 warm-ups hit
- no round used the degraded compaction path

This establishes that the local compaction implementation bounds retained
history without breaking task continuity or cache recovery. It solves the
full-history growth problem, but does not by itself make Responses the cheaper
transport.

## Decision

**Do not change the default DeepSeek route.**

Keep:

- `deepseek@default/*` as the canonical default
- `deepseek@responses/*` as an explicit opt-in route

The Responses route is viable for testing and workloads that specifically
need its endpoint contract. It is not the default because the final evidence
shows no stable Flash advantage and a material Pro regression.

## Re-evaluation criteria

Re-run the same paired suite before reconsidering the default. A new evaluation
should first identify and reduce the Responses amplification in:

- provider round count
- logical input, especially on Pro
- output tokens
- provider latency

A default-route change should require repeated evidence across more than one
real task, no success or verification regression, cache-miss input within the
existing threshold, and a consistent cost or latency advantage on both Flash
and Pro.

## Evidence location

The raw local artifacts are generated under:

- `.benchmark-results/deepseek-final-flash-20260815-main0753e336/`
- `.benchmark-results/deepseek-final-pro-20260815-main0753e336/`

These directories are intentionally gitignored. Their `summary.json`,
`paired-summary.json`, per-run metrics, verification logs, and token
optimization diagnostics are the authoritative source for the aggregates in
this document.
