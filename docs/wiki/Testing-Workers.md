# Testing Workers

Shifty 0.6.0 ships an opt-in test harness (`require "shifty/testing"`) and RSpec sugar (`require "shifty/rspec"`) so your unit tests exercise workers under the **same handoff policy the production pipeline will** (see [[Handoff-Policies]]). Neither is loaded by `require "shifty"` — they're deliberately opt-in. This page covers the parity problem they solve, `Shifty::Testing.run`, the mutation detector, the RSpec matcher and shared example, and the "test at the ceiling" guidance.

## The parity problem

A pipeline runs `:frozen`; a unit test exercises the worker's raw proc with an ordinary mutable object:

```ruby
worker.task.call(input)  # bypasses the framework — and the policy
```

The test passes; the pipeline raises. The gap closes from two directions:

1. **Worker-level policy declarations win** over pipeline defaults, so the policy travels *with* the worker. Any test that runs the worker through the framework automatically exercises production semantics.
2. **The framework path is the convenient path** — that's `Shifty::Testing.run`.

With `:frozen` as the global default, the common case requires no test configuration at all.

## `Shifty::Testing.run`

```ruby
require "shifty/testing"

Shifty::Testing.run(worker, inputs:, policy: nil, max_shifts: 10_000)
```

Feeds the inputs to the worker via a synthetic source and collects its outputs until the end-of-stream sentinel (`nil`). The worker's declared/effective policy governs each handoff, exactly as in production; the harness restores the worker's policy, supply, and Fiber afterward, so it never leaves a mark on the worker under test.

```ruby
worker = relay_worker { |v| v.upcase }
Shifty::Testing.run(worker, inputs: ["a", "b", "c"])  #=> ["A", "B", "C"]

# Parity with production — a mutating task raises under the default policy:
mutator = Shifty::Worker.new { |v| v && v << :x }
Shifty::Testing.run(mutator, inputs: [[:a]])          # raises PolicyViolation

# A worker that declared :isolated runs under :isolated:
scratch = Shifty::Worker.new(policy: :isolated) { |v| v && v << :x }
Shifty::Testing.run(scratch, inputs: [[:a]])          #=> [[:a, :x]]

# Explicit policy: override beats the worker's declaration (policy-matrix testing);
# the worker's real declaration is untouched afterward:
loose = Shifty::Worker.new(policy: :shared) { |v| v && v << :x }
Shifty::Testing.run(loose, inputs: [[:a]], policy: :frozen)  # raises PolicyViolation
loose.effective_policy                                       #=> :shared

# Non-1:1 output streams collect naturally:
evens = filter_worker { |v| v.even? }
Shifty::Testing.run(evens, inputs: [1, 2, 3, 4])      #=> [2, 4]
```

### Sentinel semantics

`nil` is Shifty's end-of-stream sentinel; collection stops at the first `nil` output. **`false` is a legitimate payload**, not end-of-stream — it flows through and gets collected:

```ruby
flipper = relay_worker { |v| !v }
Shifty::Testing.run(flipper, inputs: [true, false, true])
#=> [false, false, false]
# (relay_worker's `value &&` guard passes the false input through untouched.)
```

If a worker's task converts `nil` into something non-nil, the run would never terminate — so after `max_shifts` (default 10,000) the harness raises a diagnostic `Shifty::Error` telling you to let `nil` pass through (e.g. `value && ...`) or raise `max_shifts:`.

## The mutation detector: `mutates_input?`

```ruby
Shifty::Testing.mutates_input?(worker, input)  #=> true / false
```

Hands the task a private mutable deep copy of `input`, runs it through the framework under `:shared`, and compares the copy before and after (via `Marshal.dump`). It surfaces mutation **even when the worker's current policy permits or hides it**:

```ruby
sneaky = side_worker(policy: :isolated) { |v| v << :boo }
Shifty::Testing.mutates_input?(sneaky, [:a])  #=> true — the :isolated copy hid it in production

clean = relay_worker { |v| v + [:x] }
Shifty::Testing.mutates_input?(clean, [:a])   #=> false
```

This is exactly the information you need **before** loosening a policy — moving to `:shared` never raises, so the detector is your only warning (the silent-loosening asymmetry; see [[Handoff-Policies]]). It's also the pre-upgrade inventory tool for [[Migration-Guide-0.6]]. The input must be Marshal-dumpable; anything else raises a descriptive `Shifty::Error`.

## RSpec sugar

```ruby
# spec_helper.rb
require "shifty/rspec"   # pulls in shifty/testing; assumes RSpec is loaded
```

### The `mutate_input` matcher

Takes the input as an argument and delegates to the mutation detector:

```ruby
expect(worker).not_to mutate_input([:a])
```

The negated failure message spells out the consequences: a mutating task is only correct under `:isolated` (mutation stays local) or `:shared` (mutation is intentional); it will raise under `:frozen`.

### The `"a policy-safe worker"` shared example

Expects `worker` and `safe_input` to be defined with `let`:

```ruby
RSpec.describe "my enricher" do
  let(:worker)     { relay_worker { |v| v.merge(enriched: true) } }
  let(:safe_input) { {id: 1} }

  it_behaves_like "a policy-safe worker"
end
```

It runs two checks: the worker processes a **deeply frozen** input through the framework without raising (`Testing.run(..., policy: :frozen)`), and it does not mutate its input.

## Test at the ceiling

Policy safety is (almost) a one-way ratchet: a task correct on deeply frozen input is correct under every policy; the reverse does not hold. So the guidance is to **test under `:frozen`** — the ceiling — unless the worker explicitly declares mutation as part of its design. Consequences:

- Loosening a pipeline's policy can never break a ceiling-tested worker.
- Tightening is the only breaking direction, and tightening fails loudly with `PolicyViolation` diagnostics.

**The "almost":** `:isolated` hands the task a *copy*, so a worker depending on object **identity** (rare, but conceivable with identity-keyed caches) behaves differently there. This is the one spot where strict-passing does not imply lax-passing. If your worker cares about `equal?`, test it under `:isolated` explicitly:

```ruby
Shifty::Testing.run(worker, inputs: [thing], policy: :isolated)
```
