# Migrating to 0.6.0

Shifty 0.6.0 changes the default handoff behavior: values now arrive at each worker **deeply frozen** instead of as raw shared references (see [[Handoff-Policies]]). Most pipelines — anything already written in a non-destructive style — upgrade with no changes at all. Pipelines whose tasks mutate their inputs will raise loudly and immediately, with an error message that names the worker, the object, and the fix. This page covers what breaks, the four migration paths in order of preference, and the deprecation timeline.

## What breaks

1. **The default flips from `:shared` to `:frozen`.** Any task that mutates its input (`<<`, `map!`, `merge!`, attribute assignment) raises `Shifty::PolicyViolation` on first contact — at the offending worker, not downstream. The message tells you which worker, which object, and the two exits.

2. **Unshareable values can't cross a default-policy boundary.** IO handles, sockets, procs, lazy enumerators, and (under `:isolated`) objects with singleton methods raise `Shifty::UnshareableValue` at the handoff. Workers passing such values along must declare `policy: :shared`. Note that IO is rejected proactively under `:frozen` — but only *top-level* IO; an IO nested inside a container is silently frozen in place by `Ractor.make_shareable`, so declare `:shared` on workers handling those too.

3. **`side_worker`'s `mode:` option is deprecated.** `mode: :hardened` maps to `policy: :isolated` with a deprecation warning; any other `mode:` value warns and is ignored. Note that `side_worker` now takes an options hash, so the old *positional* form `side_worker(:hardened) { ... }` must become `side_worker(mode: :hardened)` (transitional, warns) or better, `side_worker(policy: :isolated)`. The `mode:` option (and the `:hardened` policy alias) will be **removed in 1.0.0**.

4. **The task's second argument is now a policy-governed supply proxy.** Tasks that accept `(value, supply)` — filters, batchers, anything pulling extra values mid-task — now receive a proxy responding only to `#shift`, not the raw upstream worker. Each pulled value crosses the boundary under the worker's policy, exactly like the primary intake. If your task called anything other than `#shift` on its supply argument, that code needs rework.

5. **Ruby floor is 3.2** (`required_ruby_version` in the gemspec). Shifty 0.5.0 remains available for older Rubies and the old behavior.

## Migration paths, in order of preference

### 1. Rewrite tasks non-destructively

Usually a small diff — `map!` → `map`, `<<` → `+`, `merge!` → `merge` — and the `PolicyViolation` message names the object and the worker for you. This is the best destination: zero policy declarations, zero copies, full protection. See [[Coding-Idioms-Under-Frozen]] for the full pattern table.

```ruby
# before                                  # after
relay_worker { |v| v << compute(v) }      relay_worker { |v| v + [compute(v)] }
```

### 2. Declare `:isolated` on mutation-heavy workers

When a task isn't worth rewriting, give it a private scratch copy. Correctness is preserved; the deep-copy cost is localized to exactly those workers.

```ruby
legacy = Shifty::Worker.new(policy: :isolated) { |v| gnarly_in_place_transform(v) }
```

### 3. Declare `:shared` where pass-by-reference is genuinely required

Uncopyable values, or intentional shared mutation observed downstream. This restores the pre-0.6.0 semantics for that worker only — along with its lack of protection, so use deliberately.

```ruby
log_forwarder = side_worker(policy: :shared) { |io| io.flush }
```

### 4. Blanket opt-out (large legacy codebases)

```ruby
Shifty.configure { |c| c.default_policy = :shared }
```

This reproduces 0.5.0 behavior globally, letting a team migrate worker-by-worker at its own pace. Treat it as scaffolding, not a destination — while it's in place you have none of 0.6.0's protection anywhere a worker hasn't declared its own policy.

## Inventory first: the mutation detector

Before upgrading (or before loosening any policy), let the framework tell you which workers actually mutate their inputs:

```ruby
require "shifty/testing"

Shifty::Testing.mutates_input?(worker, representative_input)
#=> true  — needs path 1, 2, or 3
#=> false — this worker upgrades clean
```

Run it across your workers with representative inputs and you have your migration worklist. This matters doubly because loosening is *silent*: moving a worker to `:shared` never raises, even if its task mutates — the detector is the only thing that will tell you. See [[Testing-Workers]].

## `:hardened` → `:isolated`: what's preserved, what changed

The old `side_worker(:hardened)` handed the block a `Marshal.load(Marshal.dump(value))` deep copy. `:isolated` uses **the same Marshal round-trip**, so both semantics and failure behavior are preserved: a value that raised under `:hardened` (a proc, an IO, a singleton-methoded object — anything Marshal rejects) still raises under `:isolated`, now as a `Shifty::UnshareableValue` with a diagnostic message instead of a bare `TypeError`. No value that used to fail will start silently succeeding, and vice versa.

(An earlier design draft had `:isolated` using `Ractor.make_shareable(copy: true)`, which would have shifted the failure set slightly — that mechanism returns a frozen copy and was rejected precisely because `:isolated` promises a *mutable* scratch copy.)

## Deprecation timeline

| Version | Status |
|---|---|
| 0.6.0 | `mode: :hardened` and `policy: :hardened` work, emit deprecation warnings, map to `:isolated` |
| 1.0.0 | `mode:` option and `:hardened` alias removed |

## A worked upgrade

```ruby
# 0.5.0 code
source = source_worker [[:foo], [:bar]]
stasher = side_worker(:hardened) { |v| v << :boo }   # old positional mode
# NOTE: on 0.6.0 this positional form raises TypeError (side_worker now
# takes an options hash) — it does NOT get the friendly deprecation
# warning. Only the keyword forms (mode:/policy:) warn.

# 0.6.0 code — same behavior, no warning
stasher = side_worker(policy: :isolated) { |v| v << :boo }

pipeline = source | stasher
pipeline.shift #=> [:foo]   — mutations evaporate, value passes through pristine
```

And remember: policy names are validated eagerly, so typos in `policy:` declarations fail at the declaration site, not three workers downstream at 2 a.m.
