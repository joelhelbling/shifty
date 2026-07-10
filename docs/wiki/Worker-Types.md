# Worker Types

Shifty's DSL (`include Shifty::DSL`) provides shorthand constructors for the common worker shapes; underneath them all is `Shifty::Worker`, and above them sits `Shifty::Gang` for treating a chain as one unit. This page is the per-type reference for 0.6.0, including how each type behaves under the default `:frozen` handoff policy (see [[Handoff-Policies]]). All DSL constructors except `source_worker` and `trailing_worker` accept an options hash that passes through to `Worker.new` — so `policy:`, `name:`, `tags:` work everywhere.

## `source_worker`

At the headwater of every pipeline: a worker that generates its own work items. Its block takes no arguments; `nil` signals end-of-stream (and once a source returns `nil`, it returns `nil` henceforth).

```ruby
worker = source_worker { "Number 9" }   # generates forever

counter = 0
finite = source_worker do               # generates until it returns nil
  if counter < 3
    counter += 1
    counter + 1000
  end
end

w1 = source_worker [0, 1, 2]            # or hand it a series
w2 = source_worker (0..2)               # ranges work too
```

A series-based source yields each element and then `nil` forever. Strings are split into characters; a bare scalar becomes a one-element series. You can also combine a series with a block, which acts as a transform: `source_worker([1,2]) { |v| v * 10 }`.

Sources are where "mutable within, immutable between" starts: build values freely in closure scope, and hand off snapshots (see [[Coding-Idioms-Under-Frozen]]).

## `relay_worker`

The most "normal" worker: accepts a value, returns a transformation of it. `nil` passes through untouched (the end-of-stream sentinel survives).

```ruby
squarer = relay_worker { |number| number ** 2 }
pipeline = source_worker(0..3) | squarer
pipeline.shift #=> 0, 1, 4, 9, nil
```

Under `:frozen`, relay tasks must be non-destructive — `v.merge(...)`, `v + [...]`, `v.with(...)`. A `v <<` raises `PolicyViolation` at this worker, by name if you gave it one.

## `side_worker`

Passes through the value it received while performing a side effect — logging, metrics, stashing. Its purpose is *intentionality*: side effects live in named, removable workers, so pulling one out of the pipeline never changes the pipeline's output.

```ruby
evens = []
even_stasher = side_worker { |value| evens << value if value.even? }
```

Policy behavior is where 0.6.0 makes the side worker's contract real:

- **Under `:frozen` (default):** a block that mutates the passed value raises `PolicyViolation`. Observation is enforced.
- **Under `:isolated`:** the block observes a private scratch copy; since a side worker's return value is discarded, its mutations simply **evaporate** and the untouched value flows on:

```ruby
source = source_worker [[:foo], [:bar]]
unsafe = side_worker(policy: :isolated) { |v| v << :boo }
pipeline = source | unsafe
pipeline.shift #=> [:foo]  — shenanigans contained
pipeline.shift #=> [:bar]
```

- **`mode:` is deprecated:** `mode: :hardened` maps to `policy: :isolated` with a warning; any other `mode:` value warns and is ignored. Removed in 1.0.0 — see [[Migration-Guide-0.6]].

## `filter_worker`

Passes through only values for which the block is truthy; falsy values are discarded (the worker pulls from its supply until something passes).

```ruby
evens_only = filter_worker { |value| value % 2 == 0 }
pipeline = source_worker(0..5) | evens_only
pipeline.shift #=> 0, 2, 4, nil
```

Every value the filter pulls mid-task crosses the boundary under the worker's policy — including the ones it discards.

## `batch_worker`

Gathers values into batches. Either a fixed size:

```ruby
batch = batch_worker gathering: 3
pipeline = source_worker(0..7) | batch
pipeline.shift #=> [0, 1, 2], then [3, 4, 5], then [6, 7], then nil
```

(the final batch may be short), or a condition — batch until the block is truthy:

```ruby
line_reader = batch_worker { |value| value.end_with?("\n") }
```

## `splitter_worker`

Accepts one value, produces an array from it, and hands off each element successively before asking its supply for more.

```ruby
splitter = splitter_worker { |value| value.split(" ") }
pipeline = source_worker(["A bold", "move westward"]) | splitter
pipeline.shift #=> "A", "bold", "move", "westward", nil
```

Every part a splitter yields is policy-governed as it crosses into the next worker — under `:frozen`, each part arrives frozen downstream.

## `trailing_worker`

Returns an array of the last *n* values — useful for rolling averages. Nothing is returned until *n* values have accumulated; new values are unshifted into position zero.

```ruby
trailer = trailing_worker 4
pipeline = source_worker(0..5) | trailer
pipeline.shift #=> [3, 2, 1, 0], then [4, 3, 2, 1], then [5, 4, 3, 2], then nil
```

New in 0.6.0: the trailing worker **hands off a snapshot** (`trail.dup`) rather than its live closure array. It keeps mutating that array across calls, and a downstream `:frozen` intake would otherwise freeze the live array in place. This is the canonical example of the builder snapshot rule — see [[Coding-Idioms-Under-Frozen]].

(Signature note: `trailing_worker(trail_length = 2)` takes the length positionally and no options hash.)

## Raw `Shifty::Worker.new`

When the DSL shapes don't fit, build a worker directly:

```ruby
worker = Shifty::Worker.new(
  supply:   upstream,           # or wire later: worker.supply = upstream
  policy:   :isolated,          # this worker's contract; validated eagerly
  name:     "enricher",         # used in PolicyViolation / UnshareableValue messages
  tags:     [:etl],             # also reported in diagnostics
  criteria: ->(w) { ... },      # when falsy, the task is bypassed (value still policy-governed)
  task:     some_callable       # or pass a block
) { |value, supply, context| ... }
```

The task's arity matters:

- **Arity 0** — a source; it cannot accept a supply (`supply=` raises). Use `handoff(value)` (which is `Fiber.yield`) to emit from inside loops.
- **Arity 1+** — `|value|` receives the policy-governed intake value.
- **Second argument** — a policy-governed supply proxy responding only to `#shift`, for tasks that pull additional values themselves (this is how filter/batch/trailing work). It is *not* the raw upstream worker.
- **Third argument** — the worker's `context`, an `OpenStruct` by default or whatever you pass as `context:`; per-worker mutable state that survives across shifts (and survives a rescued `PolicyViolation`).

A worker with no task gets a default pass-through task. `worker.effective_policy` reports the resolved policy (own declaration, else pipeline default, else global default).

## Composition: `|`, `with_policy`, `freeze!`

```ruby
pipeline = source | filter | transform | sink   # tail-returned; call shift on it

pipeline = (source | filter | transform | sink)
  .with_policy(:frozen)   # pipeline default for workers with no declaration
  .freeze!                # lock the topology; upstream walk from the tail
```

Both `with_policy` and `freeze!` walk **upstream** through the supply chain from their receiver and return it, so they chain — and both should be called on the pipeline's tail. `freeze!` locks topology only (supply wiring, Gang rosters); closure and context state stay mutable. Use `#freeze!`, never bare `#freeze`. Details in [[Handoff-Policies]].

## `Shifty::Gang`

A Gang wraps an ordered roster of workers so a whole chain acts like one worker: it has a `supply`, a `shift`, and composes with `|` like anything else.

```ruby
gang = Shifty::Gang[parser, enricher]          # or Gang.new([parser, enricher])
pipeline = reader | gang | writer
```

Policy features:

- **Construction fanout:** `Gang.new(workers, policy: :isolated)` sets the pipeline default on every roster member.
- **`with_policy` fanout:** `gang.with_policy(:shared)` does the same, chainably.
- **Append inheritance:** the gang persists its declared policy, so workers appended *after* the declaration inherit it too.
- **Member contracts win:** a roster member's own `policy:` declaration beats the gang's, per the usual precedence.
- **Chains walk through:** `(upstream | gang | tail).with_policy(:isolated)` reaches the gang's roster *and* workers upstream of it; `freeze!` walks the same path.
- **Freezing:** a frozen gang still runs, but its roster membership is locked — `append` raises `FrozenError`.
- **Criteria bypass is still governed:** when a gang's `criteria` bypasses its workers, the value crossing the gang boundary is still policy-governed at the entry worker.
