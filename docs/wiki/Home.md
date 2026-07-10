# The Shifty Framework

Shifty is a Ruby framework for building data processing pipelines out of small, cooperatively multitasking "workers." Each worker is a Fiber-backed unit of work with private state held in closure scope, connected to its neighbors only by the values it hands off. Pipelines are composed with a vertical pipe (`source | transform | sink`), and each value travels through the *entire* pipeline before the next value starts — the escalator, not the elevator.

## What's new in 0.6.0: handoff immutability policies

Shifty workers have always been easy to reason about because each one is isolated; the values flowing *between* them were, until now, the un-governed part of the system. As of 0.6.0, **values are deeply frozen at every handoff by default**. Workers that need a private scratch copy can declare `policy: :isolated`; workers that genuinely need shared mutable references can declare `policy: :shared`. Mutation bugs that used to surface as mysterious downstream corruption now either cannot happen or raise immediately at the worker responsible — with an error message that tells you exactly what to do about it.

0.6.0 also ships:

- **`#freeze!`** — lock a pipeline's topology so the pipeline you composed is the pipeline that runs ([[Handoff-Policies]])
- **`Shifty::Testing`** and RSpec helpers — unit-test workers under the same policy production will use ([[Testing-Workers]])
- **Worker `name:`** — so error messages can tell you *which* of nine anonymous workers misbehaved
- **Benchmarks** demonstrating that the `:frozen` default is essentially free at steady state ([[Performance]])
- **Deprecation of `side_worker`'s `mode: :hardened`** in favor of `policy: :isolated` ([[Migration-Guide-0.6]])

## Quick start

```ruby
require "shifty"
include Shifty::DSL

source  = source_worker (0..3)
squarer = relay_worker { |n| n ** 2 }

pipeline = source | squarer

pipeline.shift #=> 0
pipeline.shift #=> 1
pipeline.shift #=> 4
pipeline.shift #=> 9
pipeline.shift #=> nil
```

Every value the squarer receives arrives deeply frozen. Since the squarer never mutates its input, nothing changes for it — and if some future task tries a sneaky `<<`, it raises a `Shifty::PolicyViolation` right there, naming the worker and the object. Cold cases become caught-in-the-act.

## The pages

| Page | What's in it |
|---|---|
| [[Handoff-Policies]] | The three policies (`:frozen`, `:isolated`, `:shared`) in depth: guarantees, costs, failure modes, declaration and precedence, the error reference, and `#freeze!` |
| [[Coding-Idioms-Under-Frozen]] | Copy-on-write patterns, `Data.define` as the value envelope, and the "mutable within, immutable between" rule |
| [[Migration-Guide-0.6]] | What breaks, the four migration paths, and the `:hardened` deprecation timeline |
| [[Testing-Workers]] | `Shifty::Testing.run`, the mutation detector, and the RSpec matcher and shared example |
| [[Worker-Types]] | The full DSL reference: source, relay, side, filter, batch, splitter, trailing workers, raw `Worker.new`, and `Gang` |
| [[Performance]] | Benchmark results, why `:frozen` amortizes to ~nothing, and when `:isolated`'s cost matters |

## Ruby version support

| Shifty version | Ruby requirement | Notes |
|---|---|---|
| **0.6.0** | Ruby >= 3.2 | Handoff policies, `Data`-based idioms, `#freeze!`, testing harness |
| 0.5.0 | older Rubies | Last release with the previous defaults (`:shared`-style handoffs, `side_worker mode: :hardened`); remains available for older Rubies and legacy patterns |

The 3.2 floor aligns the gem with `Data.define` (the recommended value envelope — see [[Coding-Idioms-Under-Frozen]]) and mature `Ractor.make_shareable` behavior, which powers the `:frozen` policy.

## Concurrency model, in one paragraph

Shifty uses Ruby Fibers for cooperative multitasking: all workers run in a single OS thread and explicitly yield to one another, which frees you from *preemptive* hazards (races, mutexes) within a pipeline. Single-threading never made the *data* between workers safe, though — that is exactly what handoff policies now govern. The frozen, Ractor-shareable values that `:frozen` produces are also deliberately compatible with a possible future Ractor-backed worker type.
