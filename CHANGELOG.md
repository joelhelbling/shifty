# Changelog

## 0.6.0

The handoff immutability release. Values crossing worker boundaries are now
governed by a **handoff policy**, and the default changed from raw shared
references to deeply frozen values. This is a breaking change — see the
[Migration Guide](https://github.com/joelhelbling/shifty/wiki/Migration-Guide-0.6).

### Breaking changes

- **`:frozen` is the new default handoff policy.** Every value a worker
  receives is deeply frozen (`Ractor.make_shareable`) at intake. A task that
  mutates its input now raises `Shifty::PolicyViolation` at the offending
  worker — immediately and with diagnostics — instead of silently corrupting
  what downstream workers observe. Restore the old behavior per worker with
  `policy: :shared`, per pipeline with `.with_policy(:shared)`, or globally
  with `Shifty.configure { |c| c.default_policy = :shared }`.
- **Unshareable values can no longer cross a default-policy boundary.**
  IO handles, procs, lazy enumerators, and (under `:isolated`) anything
  Marshal rejects raise `Shifty::UnshareableValue` with guidance. Declare
  `policy: :shared` on workers that pass such values. Note: an IO *nested
  inside* a container is not detected — declare `:shared` for those workers.
- **The task's second argument is now a policy-governed supply proxy** that
  responds to `#shift` only, no longer the raw upstream worker object.
- **Ruby floor is 3.2** (`required_ruby_version >= 3.2`). Older Rubies stay
  on shifty 0.5.0.
- `Shifty::WorkerError` and `Shifty::WorkerInitializationError` are
  reparented under a new `Shifty::Error` base (still `StandardError`s).

### Deprecations

- **`side_worker mode: :hardened` is deprecated** (removed in 1.0.0); it maps
  to `policy: :isolated` with a warning. Semantics preserved — both use a
  Marshal deep copy. Any other `mode:` value now warns and is ignored.

### Added

- **Handoff policies**: `:frozen` (default), `:isolated` (private mutable
  deep copy; task mutations stay local), `:shared` (raw reference — the
  escape hatch). Declarable per worker (`policy:` kwarg), per pipeline
  (`.with_policy(...)` on a chain or Gang, `policy:` kwarg on Gang), and
  globally. Precedence: worker > pipeline > global.
- **Rich diagnostics**: `Shifty::PolicyViolation` (worker, policy, receiver,
  value, cause; a heuristic reports whether the mutated object is the
  handed-off value, reachable from it, or possibly unrelated) and
  `Shifty::UnshareableValue`. A rescued `PolicyViolation` does not kill the
  pipeline — the next `shift` continues with the next value.
- **Worker `name:` kwarg** for diagnostics.
- **`Shifty::Testing`** (opt-in `require "shifty/testing"`):
  `Testing.run(worker, inputs:, policy: nil)` runs a worker through the
  framework under its production policy; `Testing.mutates_input?` is the
  mutation detector — the pre-upgrade migration inventory tool.
- **RSpec sugar** (opt-in `require "shifty/rspec"`): the `mutate_input`
  matcher and the `"a policy-safe worker"` shared example.
- **`#freeze!`** locks an assembled pipeline's topology (call it on the
  tail). Rewiring — `supply=`, Gang `append`, roster mutation — raises
  `FrozenError`. Worker closure/context state stays mutable.
- **Benchmark suite** (`benchmark/handoff_policies.rb`, manual-run) with
  results in `benchmark/RESULTS.md` and on the wiki: steady-state `:frozen`
  costs ~71ns per handoff regardless of value size, with zero allocations.
- **In-depth documentation** on the
  [GitHub wiki](https://github.com/joelhelbling/shifty/wiki): policies,
  coding idioms under `:frozen`, migration, testing, worker types,
  performance.

### Fixed

- `trailing_worker` handed off its live internal array; under `:frozen` this
  is the exact aliasing bug the policies exist to catch. It now hands off a
  snapshot.
- `ostruct` is declared as a runtime dependency (no longer a default gem as
  of Ruby 4).
- CI now tests Ruby 3.2/3.3/3.4 (was 2.6/2.7/3.0); dropped the abandoned
  codeclimate-test-reporter (which pinned simplecov to a 2016 release).

## 0.5.0 and earlier

See the [release history](https://github.com/joelhelbling/shifty/releases).
