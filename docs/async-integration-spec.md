# Spec: Async / Fiber Scheduler Integration

## Goal

Allow Shifty pipelines to run cooperatively on a single thread under Ruby's
Fiber Scheduler (via the `async` gem), so that I/O-bound workers (e.g. a source
worker calling `socket.accept`) park instead of blocking the thread. Multiple
pipelines can then drive concurrent I/O from one OS thread, in the same style
as `falcon`, `async-http`, etc.

## Non-goals

- True parallelism. Workers remain cooperative; CPU-bound stages still
  serialize. Ractors are out of scope.
- Rewriting `Worker` internals. Empirical testing (Ruby 4.0.5, async 2.39)
  confirms blocking Fibers using `Fiber#resume` / `Fiber.yield` for value-
  passing compose correctly with an installed scheduler — `sleep` and I/O
  hooks fire, sibling tasks run, value cascade is undisturbed. No
  `Fiber.transfer` rewrite needed.
- Auto-installing a scheduler. Users opt in explicitly via `Shifty.run`.
- Modernizing internals (e.g. replacing `OpenStruct` with `Data.define`).
  Tracked separately.

## Approach: single repo, optional dependency

`async` is an **optional** dependency. The core gem stays zero-runtime-dep
(beyond `ostruct`). A new file `lib/shifty/async.rb` requires `async` at the
top and defines the integration. Users opt in by:

```ruby
# Gemfile
gem "shifty"
gem "async"

# application code
require "shifty/async"
```

If `async` isn't installed, `require "shifty/async"` raises `LoadError` with a
clear message pointing at the Gemfile.

### Why not a separate gem

- The integration is ~30 lines; a separate gem is more maintenance than code.
- One repo, one CI, atomic commits across core and adapter.
- Optional require gives the same "no `async` in bundles that don't want it"
  property as a separate gem.

## Ruby version

Bump gemspec floor to **Ruby 3.2**. Required for mature Fiber Scheduler
behavior and forward-compatible with `Data.define` (used later, not in this
change).

## API surface

Two module methods, added under `Shifty`:

### `Shifty.run(&block)`

Installs a scheduler for the duration of the block. Thin wrapper over
`Sync { ... }` from the async gem (`Sync` installs `Async::Scheduler` if none
is present, runs the block, tears down on exit).

```ruby
Shifty.run do
  # scheduler is installed; any Async{} children here are scheduled fibers
end
```

Behavior:
- Nesting: nested `Shifty.run` reuses the outer scheduler (Sync semantics).
- Return value: whatever the block returns.
- Exceptions in the block propagate, same as a bare `Sync { }`.

### `Shifty.drain(pipeline, on_error: nil, &block)`

Drives a pipeline to exhaustion (or until cancelled) inside an `Async` task.
Returns the `Async::Task` handle so callers can `task.stop` for cancellation.

```ruby
task = Shifty.drain(pipeline) { |value| handle(value) }
# ... later ...
task.stop  # raises Async::Stop inside the parked fiber, unwinds cleanly
```

Behavior:
- **Default error handling: isolated.** If the block (or `pipeline.shift`)
  raises, the exception is caught and logged via `Async.logger.error`. The
  sibling tasks in the same `Shifty.run` are unaffected. Rationale: listener
  pipelines (one bad request) should not tear down the server.
- **Opt-in propagation:** pass `on_error: :raise` (or any callable) to override.
  `on_error: :raise` re-raises (async will then propagate up the task tree
  and cancel siblings). A callable receives the exception and the value (if
  available) and decides what to do.
- Must be called inside a `Shifty.run` block. Calling it outside raises
  `Shifty::AsyncError` ("Shifty.drain must be called inside Shifty.run").

### Errors

New error class `Shifty::AsyncError < Shifty::WorkerError` for adapter-
specific failures (missing scheduler, bad `on_error` arg).

## What does NOT change

- `Worker`, `Gang`, `Roster`, `Taggable`, DSL — all unchanged.
- `worker.shift` semantics — unchanged. Returns `nil` on exhaustion, exactly
  as today. The async-aware loop inside `drain` simply uses the same
  `while (v = pipeline.shift)` pattern users write today.
- `|` operator — unchanged.

This is important: `require "shifty/async"` is purely additive. Code that
never calls `Shifty.run` / `Shifty.drain` runs identically to the current
release.

## File layout

```
lib/
  shifty.rb                       # unchanged
  shifty/
    worker.rb                     # unchanged
    dsl.rb                        # unchanged
    gang.rb                       # unchanged
    roster.rb                     # unchanged
    taggable.rb                   # unchanged
    version.rb                    # bump
    async.rb                      # NEW: requires "async", defines Shifty.run / Shifty.drain
spec/
  shifty/
    async_spec.rb                 # NEW: unit tests w/ a stub scheduler + integration tests w/ real Async
examples/
  multi_listener.rb               # NEW: runnable example, two TCPServer pipelines on one thread
docs/
  async-integration-spec.md       # this file
  shifty/
    async.md                      # NEW: API reference for Shifty.run / Shifty.drain
README.md                         # UPDATED: new "Concurrency with async" section
shifty.gemspec                    # UPDATED: ruby_version >= 3.2, add async as dev dep
CLAUDE.md                         # UPDATED: note shifty/async.rb in Architecture section
```

## Gemspec changes

```ruby
spec.required_ruby_version = ">= 3.2"
spec.add_development_dependency "async", "~> 2.0"
```

No new runtime dependency. README documents that users must add `gem "async"`
themselves to use `shifty/async`.

## Documentation changes

### `README.md`

Add a new section after the existing DSL/worker-type sections, titled
**"Concurrency with async (optional)"**. Contents:
1. One-paragraph motivation: I/O-bound pipelines, multiple listeners on one
   thread.
2. Setup: install `async`, `require "shifty/async"`.
3. Minimal example: one `Shifty.run` with one `Shifty.drain`.
4. Multi-pipeline example: two `Shifty.drain` calls, explanation of how
   parking on I/O lets them interleave.
5. Cancellation: capturing the task handle, `task.stop`.
6. Error handling: default-isolated, `on_error:` override.
7. Pointer to `examples/multi_listener.rb` for a runnable demo.
8. Caveat: cooperative, not preemptive — CPU-bound work still serializes.

Keep the section terse. Link to `docs/shifty/async.md` for full API reference.

### `docs/shifty/async.md` (new)

Reference doc, parallels `docs/shifty/worker.md`. Covers:
- `Shifty.run` — signature, behavior, nesting, return value, exceptions.
- `Shifty.drain` — signature, default isolation, `on_error:` options, return
  value (task handle), cancellation via `task.stop`.
- `Shifty::AsyncError` — when raised.
- Interaction notes: why Worker fibers Just Work under the scheduler, what
  *won't* benefit (pure-CPU pipelines), what to do about long CPU stretches
  inside an otherwise-I/O pipeline (`Async::Task.current.yield` or move to a
  separate thread/Ractor).

### `examples/multi_listener.rb` (new)

A runnable file demonstrating two `TCPServer`-backed source workers driven
concurrently inside one `Shifty.run`. Heavily commented. Includes a one-line
shell command in a comment for testing it with `curl` or `nc`.

### `CLAUDE.md`

Add `lib/shifty/async.rb` to the Architecture bullet list with a one-line
description: "Optional Fiber-Scheduler integration via the `async` gem;
provides `Shifty.run` / `Shifty.drain`. Loaded by `require 'shifty/async'`."

## Testing strategy

Two layers:

### 1. Unit tests with a mock scheduler

For testing `Shifty.drain` logic (loop termination on `nil`, error isolation,
`on_error` dispatch, task handle return, scheduler-presence check) without
real I/O or timing dependence. Use a minimal stub conforming to the
`Fiber::SchedulerInterface` shape — just enough to satisfy `Sync` and let us
inspect what tasks were created and how they were stopped.

These tests run fast (<10ms each) and are deterministic.

### 2. Integration tests with real `Async::Scheduler`

A small set (target: ~5 tests) using real `Sync { }` and real I/O via
`IO.pipe` (avoiding TCP/DNS flakiness). Covers:
- Two pipelines, each parks on an `IO.pipe` read; writes to one wake only its
  pipeline.
- `task.stop` unwinds a parked source cleanly.
- Exception in one `drain` does not cancel sibling (with default
  isolation).
- `on_error: :raise` does cancel siblings.
- Value cascade through a real `source | relay | tail` works under scheduler.

Integration tests get a `:integration` tag so they can be filtered out for
quick local runs (`rspec --tag ~integration`).

`spec_helper` conditionally `require "shifty/async"` only when `async` is
available, so the suite still runs (skipping async specs) if a contributor
hasn't bundled it.

## Implementation sketch

```ruby
# lib/shifty/async.rb
require "async"
require "shifty"

module Shifty
  class AsyncError < WorkerError; end

  def self.run(&block)
    Sync(&block)
  end

  def self.drain(pipeline, on_error: nil, &block)
    raise AsyncError, "Shifty.drain must be called inside Shifty.run" unless Fiber.scheduler

    Async do |task|
      while (value = pipeline.shift)
        block.call(value)
      end
    rescue Async::Stop
      raise  # let cancellation propagate normally
    rescue => e
      case on_error
      when nil       then Async.logger.error(self) { e }
      when :raise    then raise
      when Proc      then on_error.call(e)
      else raise AsyncError, "on_error must be nil, :raise, or a callable"
      end
    end
  end
end
```

## Versioning

Minor bump: **0.4.x → 0.5.0**. New API surface and a Ruby-version floor
bump warrant a minor, not a patch. No breaking changes to existing API.

## Out of scope (follow-up tickets)

- `Gang#drain` convenience method. Worth doing once `Shifty.drain` proves
  out, since a Gang *is* effectively a pipeline.
- `Shifty.run` SIGTERM/SIGINT trapping. Library code shouldn't install signal
  handlers by default; revisit if users ask.
- A `concurrent_worker` DSL method that fans `n` items out across child
  `Async` tasks. Interesting follow-up; needs its own brainstorming pass.
- Immutability pass (`Data.define` for Worker context, etc.) — separate
  effort.
- Migrating off `ostruct` runtime dep (it's gem-installed but `Data.define`
  could replace its only usage in `Worker#initialize`).

## Open questions / risks

1. **Logger:** `Async.logger.error` is the natural default sink for isolated
   errors, but it's silent if no logger is configured. Should `Shifty` set a
   default `STDERR` logger if none present? Leaning yes, but it's a small
   detail.
2. **`Sync` vs `Async`:** `Sync` runs synchronously and waits for children.
   `Async` returns a task immediately. `Shifty.run` uses `Sync` — confirmed
   intentional (the block reads top-to-bottom; users expect it to block).
3. **Backwards-compat smoke test:** add one spec that loads `shifty` (NOT
   `shifty/async`) and confirms `Shifty.const_defined?(:AsyncError)` is
   false, to guarantee the optional require really is optional.
4. **Real-I/O integration test on CI:** macOS CI uses kqueue, Linux CI uses
   epoll. The `IO.pipe` approach works on both, so we're fine without
   per-platform branching.
