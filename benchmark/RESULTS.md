# Handoff policy benchmark results

Run: `bundle exec ruby benchmark/handoff_policies.rb`
Environment: Ruby 4.0.5 (arm64-darwin25), Apple Silicon. 2026-07-10.
(Re-run on your own hardware; relative ordering is what matters.)

## Method note (read first)

Rows labeled *fresh value* construct a new value inside each iteration, so
they include construction cost — that keeps `:frozen`'s freeze bit honest
(freezing is once-per-object; a pre-built value would be frozen after the
first iteration). The *steady state* row uses a pre-built, already-shareable
value and measures the policy call alone. Compare fresh rows against the
`:shared` fresh row (same construction overhead); read the steady-state row
as the per-handoff cost once a value is shareable.

`:hardened` (legacy) has no separate row: its mechanism — a Marshal
round-trip — is exactly what `:isolated` uses, so the `:isolated` rows are
its numbers.

## Per-handoff throughput (i/s; higher is better)

| Shape | `:shared` (fresh) | `:frozen` first handoff (fresh) | `:frozen` steady state | `:isolated` (fresh) | `:isolated` on already-frozen (§8.3) |
|---|---|---|---|---|---|
| small string token | 10.56M | 5.02M | **14.04M** | 1.44M | 1.57M |
| array, 100 strings | 140.8k | 84.3k | **14.12M** | 34.5k | 46.6k |
| hash, 100 pairs | 48.6k | 38.4k | **13.87M** | 14.1k | 20.4k |
| nested document, ~5k nodes | 9.9k | 5.3k | **13.74M** | 1.9k | 2.4k |
| deep nesting, 500 levels | 49.0k | 21.3k | **13.99M** | 8.5k | 10.8k |

## Allocations per handoff (GC pressure)

| Shape | `:shared` | `:frozen` (steady) | `:isolated` |
|---|---|---|---|
| small string token | 0 | 0 | 5 |
| array, 100 strings | 0 | 0 | 105 |
| hash, 100 pairs | 0 | 0 | 205 |
| nested document | 0 | 0 | 1,711 |
| deep nesting, 500 levels | 0 | 0 | 504 |

## Findings

1. **The §8.2 amortization claim holds.** Once a value is shareable,
   `:frozen`'s per-handoff cost is a flat ~71ns **independent of value
   size** (13.7–14.1M i/s across every shape) with zero allocations.
   In an N-worker pipeline, only the first boundary pays the freeze
   traversal; boundaries 2..N are effectively free. Combined with
   copy-on-write task code, per-boundary cost is proportional to the
   *change*, not the value.
2. **First-handoff freeze costs roughly 0.6–1.9× the value's own
   construction cost** (e.g. ~4.8µs extra for a 100-string array that
   costs ~7.1µs to build) — paid once per object graph, not per hop.
3. **`:isolated` is the expensive policy, as designed**: 3–7× slower than
   `:shared` per boundary *per hop*, and the only policy that allocates
   (a full copy of the graph per boundary — 1,711 objects per handoff for
   the ~5k-node document). This is why it is not the default.
4. **§8.3 fast-path decision: keep option (b) — no fast path.** The
   "already-frozen" column is the pure Marshal cost on a pre-built value
   (no construction overhead): 92µs for the deep-nested shape, 21µs for
   the mid array, versus ~71ns if a `Ractor.shareable?` check skipped
   the copy — so a fast path would make those handoffs roughly three
   orders of magnitude cheaper *when inputs are already shareable*.
   It still loses: it would hand the task a frozen object where the
   `:isolated` contract promises a mutable scratch copy. Contract
   simplicity wins at this gem's scale. Reopen trigger: a real workload
   where `:isolated` boundaries dominate and their inputs are typically
   already shareable.
5. **The `:frozen` default is vindicated**: it is the only policy that is
   simultaneously safe and, at steady state, the cheapest of the three.
