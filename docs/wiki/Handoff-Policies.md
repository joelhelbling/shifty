# Handoff Policies

A handoff policy governs how a value crosses a worker boundary. As of 0.6.0 there are three: **`:frozen`** (the default — the value is deeply frozen and passed by reference), **`:isolated`** (the task gets a private mutable deep copy), and **`:shared`** (the raw reference passes through, as in classic Shifty). Policy is applied at *intake* — the moment a worker pulls a value across its boundary — and can be declared per worker, per pipeline/Gang, or globally. This page covers each policy's contract, how declarations compose, the error classes, and the companion `#freeze!` topology lock.

## The three policies

### `:frozen` — the default

The value is deeply frozen in place via `Ractor.make_shareable(value)` and passed **by reference**. Zero copies. Any attempt to mutate the value — or anything reachable from it — raises immediately, at the worker that misbehaved.

- **What the task receives:** a frozen shared reference.
- **Guarantee:** no worker can mutate a value observed by any other worker.
- **Cost:** freeze traversal only; no copying, no allocations. Amortized cost is proportional to *newly created* objects, not graph size — at steady state it's a flat ~71ns per handoff regardless of value size (see [[Performance]]).
- **Developer contract:** tasks must be non-destructive. "Apparent mutation" is expressed as copy-on-write: `value.with(...)`, `arr + [x]`, `hash.merge(...)` (see [[Coding-Idioms-Under-Frozen]]).
- **Failure modes:** a mutating task raises `Shifty::PolicyViolation`; an unfreezable value raises `Shifty::UnshareableValue` at the handoff. IO values are rejected **proactively** — see below.

### `:isolated` — the scratch-copy mode

The task receives a **deep, mutable copy** of the value, produced by a `Marshal.load(Marshal.dump(value))` round-trip. The task may mutate its copy freely — `<<` and friends work exactly as in classic Shifty code — but nothing leaks back upstream. Whatever the task returns is what flows downstream, mutations included.

Why Marshal and not `Ractor.make_shareable(copy: true)`? Because `make_shareable(copy: true)` returns a *frozen* copy, which cannot satisfy `:isolated`'s contract of a mutable scratch value.

- **What the task receives:** a private mutable deep copy.
- **Guarantee:** upstream references are protected; task-local mutation is invisible outside the worker.
- **Cost:** a full deep copy of the value graph per worker, per value, plus the corresponding GC pressure. This is why it is not the default.
- **Use cases:** mutation-heavy legacy task code not worth rewriting; side workers (this is the old `:hardened` semantics, generalized); untrusted or third-party task procs.
- **Side workers:** a side worker's return value is discarded, so under `:isolated` its mutations simply evaporate — the behavior the documentation always wished for.
- **Failure modes:** values Marshal cannot dump raise `Shifty::UnshareableValue`: Procs, lazy enumerators, File/IO handles, StringIO, objects with singleton methods.

### `:shared` — the escape hatch

The raw object reference passes through untouched. This is the pre-0.6.0 default behavior, renamed to say what it actually is. Two legitimate reasons to reach for it:

1. **Intentional in-place mutation** of a value downstream workers are meant to observe.
2. **Uncopyable / unfreezable values** — IO handles, sockets, procs, lazy enumerators. Sometimes you aren't asking permission to mutate; you're asking for pass-by-reference.

- **Guarantee:** none. The framework provides no protection on this boundary.
- **Cost:** zero.
- **Failure mode of incorrect task code:** silent corruption downstream — the very thing 0.6.0 exists to prevent. Reach for `:shared` deliberately, not reflexively.

### Comparison

| | `:frozen` (default) | `:isolated` | `:shared` |
|---|---|---|---|
| What the task receives | frozen shared reference | private mutable deep copy | raw shared reference |
| Upstream protected from mutation | yes (mutation raises) | yes (mutation is local) | no |
| Mutation in task code | raises `PolicyViolation` | works, stays local | works, leaks |
| Copying per handoff | none | full graph (Marshal round-trip) | none |
| Freeze traversal per handoff | delta only (amortized) | none | none |
| GC pressure | none | high | none |
| Handles unshareable values (IO, procs, …) | no — `UnshareableValue` | no — `UnshareableValue` (Marshal's failure set) | yes |
| Failure mode of incorrect task code | loud, local, immediate | silent no-op upstream | silent corruption downstream |

## Declaring policy, and who wins

Policy may be declared at three levels, narrowest to widest. **Precedence: worker beats pipeline beats global.**

```ruby
# 1. Worker level — part of the worker's contract; always wins
worker = Shifty::Worker.new(policy: :isolated) { |v| v << transform(v) }
side_worker(policy: :shared) { |v| logger.info(v) }

# 2. Pipeline level — a default applied to workers that didn't declare their own
pipeline = (source | parser | enricher | sink).with_policy(:frozen)

# Gangs take a policy at construction or via with_policy; either fans out
# to the roster, and workers appended later inherit it:
gang = Shifty::Gang.new([a, b], policy: :isolated)
Shifty::Gang[a, b].with_policy(:shared)

# 3. Global default — :frozen out of the box
Shifty.configure { |c| c.default_policy = :frozen }
```

Details worth knowing:

- `with_policy` walks **upstream** through the supply chain from the node you call it on, so call it on the pipeline's tail (the thing you'd call `shift` on). It returns its receiver, so it chains.
- A worker's own `policy:` declaration is its **contract** and is never overridden by a pipeline default. This is what makes testing reliable (see [[Testing-Workers]]): any harness that runs the worker through the framework automatically exercises production semantics.
- Policy names are validated **eagerly**, at declaration time — `Worker.new(policy: :bogus)`, `Gang.new(..., policy: :bogus)`, `with_policy(:bogus)`, and `c.default_policy = :bogus` all raise `ArgumentError` where the typo was written, not at first shift.
- `:hardened` is accepted as a deprecated alias for `:isolated` (with a warning) until 1.0.0 — see [[Migration-Guide-0.6]].
- A worker's resolved policy is inspectable as `worker.effective_policy`.

### Where policy is applied

Policy is applied at **intake**: the single seam every value crosses when a worker pulls it from its supply. This includes:

- values pulled mid-task — a task's second argument is a policy-governed supply proxy that responds only to `#shift`, so when a filter, batch, or trailing worker pulls extra values itself, each one crosses the boundary under the same policy;
- values that bypass a worker's task because its `criteria` said no — the value still crosses the boundary, so it is still governed;
- each part a splitter yields — every part arrives frozen downstream.

### The terminal-output caveat

Policies govern **worker-to-worker** boundaries only. What the *last* worker returns to your calling code has not crossed another intake, so it is not policy-governed: under `:frozen` it may or may not already be frozen, depending on what the final task did. If your calling code needs a guarantee about the terminal value, establish it yourself (freeze it, copy it, or wrap the pipeline's tail with one more pass-through worker).

## Error reference

Both errors inherit from `Shifty::PolicyError` (< `Shifty::Error` < `StandardError`) and expose `#worker`, `#policy`, and `#value`. Give workers a `name:` and they'll introduce themselves properly in the message.

### `Shifty::PolicyViolation`

Raised when a task mutates a value it received under a policy that forbids mutation. The framework catches the raw `FrozenError` at the task call site and re-raises it wrapped — never masked; the original is available as `#cause`.

Attributes: `worker`, `policy`, `receiver` (the object the task tried to mutate, from `FrozenError#receiver`), `value` (the handed-off value), `cause`.

The message locates the receiver relative to the handed-off value using a bounded reachability walk, producing one of three descriptions:

1. *"…the handed-off value itself"* — the task mutated exactly what it was handed.
2. *"…reachable from the handed-off value"* — the task mutated something nested inside it (e.g. `v[:items] << 3`).
3. *"…which may be unrelated to the handed-off value … inspect both to judge"* — the `FrozenError` came from some other frozen object in the task's own code (a frozen string literal, a constant); the policy machinery reports honestly rather than misattributing. (The walk gives up past 50,000 nodes and falls back to this message rather than risk masking the violation.)

Every message ends with the two documented exits: make the task non-destructive (`map` instead of `map!`, `value.with(...)`, `arr + [x]`, `hash.merge(...)`), or declare `policy: :isolated` / `policy: :shared` on that worker.

**Recovery semantics:** a rescued `PolicyViolation` does not kill the pipeline. The raising Fiber is terminated and can never be resumed, so the worker discards it; the next `shift` builds a fresh Fiber and continues with the next value. Closure and context state survive — only the loop restarts. **Exception:** a `#freeze!`-d pipeline cannot rebuild its Fiber, so a violation there ends the pipeline — the topology guarantee wins.

```ruby
source  = source_worker [[:bad], [:good]]
mutator = Shifty::Worker.new { |v| (v == [:bad]) ? v << :x : v }
pipeline = source | mutator

begin
  pipeline.shift
rescue Shifty::PolicyViolation => e
  e.worker   #=> the mutator
  e.policy   #=> :frozen
  e.receiver #=> [:bad]
  e.cause    #=> the original FrozenError
end

pipeline.shift #=> [:good]  — the pipeline lives on
```

### `Shifty::UnshareableValue`

Raised at the handoff itself when a value cannot cross the boundary under the effective policy. The failure sets differ per policy:

- **Under `:frozen`:** anything `Ractor.make_shareable` rejects (Procs, lazy enumerators, …), wrapped from the underlying `Ractor::Error` — **plus IO values, rejected proactively**. `make_shareable` does *not* reject an IO; it would silently freeze the live handle in place, a process-wide side effect on shared resources like loggers or `$stdout`. Shifty checks for top-level IO before calling it, and the handle is left untouched and usable.
- **Under `:isolated`:** anything Marshal cannot dump — Procs, lazy enumerators, File/IO, StringIO, objects with singleton methods.

The message names the value's class and offers the exits: declare `policy: :shared` on this worker (raw pass-by-reference), or restructure the value.

**Caveat:** only a *top-level* IO is detected under `:frozen`. An IO nested inside a container (`{log: $stdout}`) will be silently frozen in place by `make_shareable`. Declare `:shared` on workers handling such values.

### The silent-loosening asymmetry

Error wrapping only catches motion in the *strict* direction. Moving **looser** — `:frozen`/`:isolated` → `:shared` — never raises: a task that was harmlessly mutating its private copy (or that would have raised) now mutates the live shared value, silently. No exception will ever fire. Before loosening any worker's policy, run the mutation detector — `Shifty::Testing.mutates_input?(worker, input)` — to learn whether the task mutates its input at all (see [[Testing-Workers]]).

## `#freeze!` — locking the topology

The same intentionality argument applies to the pipeline itself: `supply=` and Gang appends allow a fully assembled pipeline to be rewired mid-stream. `#freeze!` makes "the pipeline you composed is the pipeline that runs" a guarantee rather than a convention.

```ruby
pipeline = (source_worker([1, 2, 3]) | relay_worker { |v| v * 2 }).freeze!

pipeline.shift                 #=> 2      — a frozen pipeline still runs
pipeline.supply = other_source #=> raises FrozenError
```

What you need to know:

- `#freeze!` locks the node you call it on **and everything upstream** via the supply chain — so call it on the pipeline's **tail**. Freezing a mid-chain node leaves downstream nodes mutable.
- Worker closure and context state stay mutable — **only the topology freezes**. Stateful workers (batch, trailing, custom accumulators) keep working.
- Freezing a `Gang` locks its roster membership as well: `append` (and any roster mutation) raises `FrozenError` afterward. The freeze walk continues past the gang to upstream workers.
- Each worker materializes its lazy state (default task, Fiber) before freezing, so freezing can't surprise it mid-shift. Which is also why you should call `#freeze!` and **not** plain `Object#freeze` — bare `freeze` skips that materialization and will break the worker at its next shift.
- As noted above, a `#freeze!`-d pipeline cannot recover from a `PolicyViolation` (no Fiber rebuild).
- `#freeze!` returns its receiver, so it chains: `(a | b | c).with_policy(:frozen).freeze!`.

See also: [[Coding-Idioms-Under-Frozen]] for writing tasks that thrive under the default, and [[Migration-Guide-0.6]] for moving existing pipelines over.
