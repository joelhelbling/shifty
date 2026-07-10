# Performance

Shifty 0.6.0's `:frozen` default was chosen on a claim: deep-freezing at every handoff amortizes to approximately nothing, while deep-copying (`:isolated`) does not. The benchmark suite in `benchmark/` verifies it. Headline: once a value is shareable, `:frozen` costs a flat **~71ns per handoff with zero allocations, independent of value size** — at steady state it is the *cheapest* of the three policies, not just the safest. Numbers below are from Apple Silicon; re-run on your own hardware — the relative ordering is what matters.

## Method note (read first)

Rows labeled *fresh value* construct a new value inside each iteration, so they include construction cost — that keeps `:frozen`'s freeze bit honest (freezing is once-per-object; a pre-built value would be frozen after the first iteration). The *steady state* column uses a pre-built, already-shareable value and measures the policy call alone. Compare fresh columns against the `:shared` fresh column (same construction overhead); read the steady-state column as the per-handoff cost once a value is shareable.

`:hardened` (legacy) has no separate row: its mechanism — a Marshal round-trip — is exactly what `:isolated` uses, so the `:isolated` columns are its numbers.

## Per-handoff throughput (i/s; higher is better)

| Shape | `:shared` (fresh) | `:frozen` first handoff (fresh) | `:frozen` steady state | `:isolated` (fresh) | `:isolated` on already-frozen |
|---|---|---|---|---|---|
| small string token | 10.56M | 5.02M | **14.04M** | 1.44M | 1.57M |
| array, 100 strings | 140.8k | 84.3k | **14.12M** | 34.5k | 46.6k |
| hash, 100 pairs | 48.6k | 38.4k | **13.87M** | 14.1k | 20.4k |
| nested document, ~5k nodes | 9.9k | 5.3k | **13.74M** | 1.9k | 2.4k |
| deep nesting, 500 levels | 49.0k | 21.3k | — | 8.5k | 10.8k |

## Allocations per handoff (GC pressure)

| Shape | `:shared` | `:frozen` (steady) | `:isolated` |
|---|---|---|---|
| small string token | 0 | 0 | 5 |
| array, 100 strings | 0 | 0 | 105 |
| hash, 100 pairs | 0 | 0 | 205 |
| nested document | 0 | 0 | 1,711 |
| deep nesting, 500 levels | 0 | 0 | 504 |

## Findings

1. **The amortization claim holds.** Once a value is shareable, `:frozen`'s per-handoff cost is a flat ~71ns **independent of value size** (13.7–14.1M i/s across every shape) with zero allocations. In an N-worker pipeline, only the first boundary pays the freeze traversal; boundaries 2..N are effectively free. Combined with copy-on-write task code, per-boundary cost is proportional to the *change*, not the value.
2. **First-handoff freeze costs roughly 0.6–1.9× the value's own construction cost** (e.g. ~4.8µs extra for a 100-string array that costs ~7.1µs to build) — paid once per object graph, not per hop.
3. **`:isolated` is the expensive policy, as designed**: 3–7× slower than `:shared` per boundary *per hop*, and the only policy that allocates — a full copy of the graph per boundary, 1,711 objects per handoff for the ~5k-node document. This is why it is not the default.
4. **No `shareable?` fast path for `:isolated`.** An already-frozen input can't be mutated by anyone, so `:isolated` could skip the copy — but the fast path would hand the task a frozen object where its contract promises a mutable scratch copy. Marshal only gains ~25–35% on already-frozen values (it re-serializes regardless), so contract simplicity wins at this gem's scale. Reopen trigger: a real workload where `:isolated` boundaries dominate and its inputs are typically already shareable.
5. **The `:frozen` default is vindicated**: it is the only policy that is simultaneously safe and, at steady state, the cheapest of the three. Freeze once, shift forever.

## Why `:frozen` amortizes

MRI marks objects shareable once `Ractor.make_shareable` has blessed them, and the traversal short-circuits on already-shareable subgraphs. So in a `:frozen` pipeline, the *first* handoff pays a full traversal of the value; every subsequent handoff — through however many downstream workers — traverses only objects created since the previous one. Write your tasks copy-on-write ([[Coding-Idioms-Under-Frozen]]) and each worker creates only delta-sized new structure, so each boundary freezes only that delta. The value's bulk rides through the whole pipeline on that flat ~71ns already-shareable check, allocating nothing.

## When `:isolated`'s cost matters

`:isolated` copies the **entire value graph at every boundary it governs** — per worker, per value. Rules of thumb:

- **Token-sized values, a few `:isolated` workers:** noise. Don't think about it.
- **Large values (parsed documents, big collections) through `:isolated` boundaries:** a serious tax, in both CPU (3–7× vs `:shared`) and GC pressure (thousands of allocations per handoff). Often the GC cost outstrips the copy CPU itself.
- **Many `:isolated` workers in one pipeline:** costs multiply — nine `:isolated` workers means nine full copies and nine graphs of garbage per value.

The remedy is targeted: keep `:isolated` on exactly the workers that need a scratch copy, and migrate hot ones to non-destructive tasks under `:frozen` (see [[Migration-Guide-0.6]]). `Shifty::Testing.mutates_input?` tells you which workers actually still need it ([[Testing-Workers]]).

## Re-running the benchmarks

```
bundle exec ruby benchmark/handoff_policies.rb
```

Results are written up in [`benchmark/RESULTS.md`](https://github.com/joelhelbling/shifty/blob/main/benchmark/RESULTS.md). Absolute numbers vary by hardware and Ruby version; the shape of the results — flat steady-state `:frozen`, graph-proportional `:isolated` — should not.
