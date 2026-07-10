**Status:** Implemented in 0.6.0 (see [feature-implementation-plan.md](feature-implementation-plan.md))
**Target:** 0.6.0 (pre-1.0 minor carrying the breaking change)
**Author:** Joel Helbling
**Last updated:** 2026-07-10

> **Post-implementation corrections.** Empirical spikes during Phase 1
> falsified three mechanism claims below; the shipped code follows the
> corrected behavior (design intent unchanged):
>
> 1. **§3.2/§10.1:** `:isolated` uses a **Marshal round-trip**, not
>    `Ractor.make_shareable(copy: true)` — the latter returns a *frozen*
>    copy and cannot provide the mutable scratch copy the contract
>    promises. Consequently `:hardened` → `:isolated` preserves the exact
>    mechanism as well as the semantics.
> 2. **§3.3/§10.1:** `make_shareable` does **not** reject IO handles or
>    singleton-methoded objects — it silently freezes a live IO *in
>    place*, process-wide (and `copy: true` leaks a file descriptor). The
>    implementation therefore detects top-level IO proactively and raises
>    `UnshareableValue` before calling `make_shareable`. Only Proc and
>    `Enumerator::Lazy` (and StringIO) are rejected naturally.
> 3. **§5.3/§11.4:** `PolicyConflict` was dropped entirely — with worker
>    declarations authoritative and pipeline policy default-only, no
>    violable composition rule exists. Reopen alongside a "strict Gang".
>
> Also: §5.4's `Worker#task=` never existed; `#freeze!`'s motivation is
> `supply=`/Roster rewiring. §8.2's amortization claim was validated by
> benchmarks (`benchmark/RESULTS.md`): steady-state `:frozen` ≈ 71ns per
> handoff, independent of value size.
---

# Handoff Immutability Policies

## 1. Motivation

Shifty's core strength is that individual workers are simple to reason about: each
worker is an isolated unit of work with private state held in closure scope, connected
to its neighbors only by the values it receives and hands off. But that strength has a
shadow. The *connascence buried in the values passed between workers* remains
unmanaged. Every handoff is a shared Ruby object reference, which means:

- A worker four steps into a pipeline can mutate a value (`<<`, `map!`, `merge!`,
  attribute assignment) and silently corrupt what workers five through nine observe.
- Because the escalator model moves each value through *every* worker before the next
  value starts, the symptom of such a mutation typically surfaces far downstream from
  its cause. Failure locality is poor; debugging is archaeology.
- Side workers — whose entire contract is "observe, don't modify" — cannot actually be
  held to that contract. The current `:hardened` mode acknowledges this by handing side
  workers a `Marshal.load(Marshal.dump(value))` deep copy, at significant cost.

Immutability addresses Shifty exactly where it is weakest. Workers stay easy to reason
about *individually*; immutable handoffs make the *data space between them* equally
tractable. Mutation bugs stop being possible-but-invisible and become either impossible
(isolated copies) or immediately loud (`FrozenError` at the offending worker).

Strong typing (e.g. Sorbet) would extend these guarantees further, but is a separate
concern and a separate developer choice. It is explicitly out of scope here (§12).

---

## 2. Summary of the Change

1. Introduce a **handoff policy** governing how each value crosses a worker boundary.
2. Three policies: **`:frozen`** (new default), **`:isolated`**, and **`:shared`**.
3. Policy is declarable at the **worker** level and at the **pipeline/Gang** level;
   worker declarations take precedence (§5).
4. The existing `:hardened` option is subsumed by `:isolated` and deprecated (§10).
5. Raw `FrozenError`s arising from policy violations are caught by the framework and
   re-raised as `Shifty::PolicyViolation` with pipeline-aware diagnostics (§6).
6. A test harness and RSpec helpers ensure unit tests exercise workers under the same
   policy the pipeline will (§9).

This is a breaking change in default behavior and warrants a major version bump.

---

## 3. The Three Policies

### 3.1 `:frozen` — the new default

The value is **deeply frozen** at handoff via `Ractor.make_shareable(value)` and passed
**by reference**. Zero copies. Any attempt to mutate the value (or anything reachable
from it) raises immediately, at the worker that misbehaved.

- **Guarantee:** no worker can mutate a value observed by any other worker.
- **Cost:** freeze traversal only; no copying, no extra garbage. Amortized cost is
  proportional to *newly created* objects, not graph size (§8.2).
- **Developer contract:** tasks must be non-destructive. "Apparent mutation" is
  expressed as copy-on-write: `value.with(...)`, `arr + [x]`, `str + "suffix"`,
  `hash.merge(...)` (§7).

### 3.2 `:isolated` — compatibility / scratch-copy mode

The worker's task receives a **deep, mutable copy** of the value, produced by
`Ractor.make_shareable(value, copy: true)` where available (falling back to
`Marshal.load(Marshal.dump(value))`). The task may mutate its copy freely — `<<` and
friends work exactly as in classic Shifty code — but nothing leaks back to the
upstream reference (the supplying worker's closure state, a source's recirculating
value, etc.). Whatever the task returns/hands off is what flows downstream, mutations
included.

- **Guarantee:** upstream references are protected; task-local mutation is invisible
  outside the worker.
- **Cost:** full deep copy of the value graph **per worker, per value**, plus the
  corresponding GC pressure. This is why it is not the default (§8.1).
- **Use cases:** mutation-heavy legacy task code not worth rewriting; side workers
  (this is precisely the old `:hardened` semantics, generalized); untrusted or
  third-party task procs.
- **Note for side workers:** the return value of a side worker is discarded, so under
  `:isolated` a side worker's mutations simply evaporate — the behavior the
  documentation always wished for.

### 3.3 `:shared` — the escape hatch

The raw object reference is passed through untouched. This is today's default
behavior, renamed to say what it actually is.

There are two legitimate reasons to reach for `:shared`, and the name is chosen to
cover both:

1. **Intentional in-place mutation** of a value that downstream workers are meant to
   observe.
2. **Uncopyable / unfreezable values**: IO handles, sockets, lazy enumerators, procs,
   objects with singleton methods, or anything else that `make_shareable` (or Marshal)
   rejects. Sometimes the developer is not asking permission to mutate; she is asking
   for pass-by-reference.

- **Guarantee:** none. The framework provides no protection on this boundary.
- **Cost:** zero.

### 3.4 Policy comparison

| | `:frozen` (default) | `:isolated` | `:shared` |
|---|---|---|---|
| What the task receives | frozen shared reference | private mutable deep copy | raw shared reference |
| Upstream protected from mutation | yes (mutation raises) | yes (mutation is local) | no |
| Mutation in task code | raises `PolicyViolation` | works, stays local | works, leaks |
| Copying per handoff | none | full graph | none |
| Freeze traversal per handoff | delta only (amortized) | none | none |
| GC pressure | minimal | high | none |
| Handles unshareable values (IO, procs, …) | no — raises at handoff | no — raises at handoff | yes |
| Failure mode of incorrect task code | loud, local, immediate | silent no-op upstream | silent corruption downstream |

---

## 4. Why `:frozen` Is the Right Default

### 4.1 The candidates

- **`:shared` (status quo):** preserves silent-corruption bugs; rejected.
- **`:isolated`:** attractive because existing task code keeps working verbatim — but
  it deep-copies the entire value graph at *every* boundary. A nine-worker pipeline
  copies every value nine times and generates nine graphs of garbage. For token-sized
  values this is noise; for parsed documents or large collections it is a serious,
  hard-to-work-around tax. Defaults should not carry O(graph) costs per hop.
  (This is also, historically, why `:hardened` was never made the default: the
  Marshal round-trip was too expensive. `make_shareable(copy: true)` is cheaper, but
  it is the same complexity class.)
- **`:frozen`:** zero-copy, and its freeze cost amortizes to the size of the *change*
  rather than the size of the value (§8.2). It is the only policy that is
  simultaneously safe and cheap at scale.

### 4.2 The trade-off being accepted

`:frozen` will briefly surprise developers whose task code mutates its input. That
surprise is deliberate, and it is a *well-behaved* surprise:

- It arrives **immediately**, at the exact worker that misbehaved — not downstream.
- It arrives as a rich `PolicyViolation` naming the receiver and offering two
  documented exits (rewrite non-destructively, or declare `:isolated`/`:shared` on
  that worker) (§6).
- An early, loud, explained error is strictly preferable to cumbersome performance
  problems (an `:isolated` default) or silent data corruption (a `:shared` default).

### 4.3 The synergy that makes it pleasant

`:frozen` as default and copy-on-write as idiom are not two separate decisions.
Structural sharing (`Data#with` copying member *references*, `arr + [x]` sharing
elements) is only safe because shared substructure is frozen; and copy-on-write is
what makes frozen values ergonomic. Each half makes the other work (§7, §8).

---

## 5. API Design

### 5.1 Declaring policy

Policy may be declared at three levels, from narrowest to widest:

```ruby
# 1. Worker level — part of the worker's contract
worker = Shifty::Worker.new(policy: :isolated) { |v| v << transform(v) }

# DSL flavors (names illustrative):
side_worker(policy: :shared) { |v| logger.info(v) }

# 2. Pipeline / composition level — default for undeclared workers
pipeline = (source | parser | enricher | sink).with_policy(:frozen)

# 3. Global default — :frozen out of the box
Shifty.configure { |c| c.default_policy = :frozen }
```

### 5.2 Precedence: worker beats pipeline beats global

A worker-level declaration is part of that worker's **contract** and always wins.
Pipeline-level policy is a *default applied to undeclared workers*, not an override.
This rule is what makes testing reliable (§9): any harness that runs a worker through
the framework automatically exercises the policy that production will.

### 5.3 Build-time validation

Because policy is part of the worker contract, mismatches can be detected at
composition time — at the `|`, not mid-stream:

- A worker declaring `:shared` (e.g. "I pass an IO handle downstream") composed into a
  pipeline whose policy configuration forbids it can raise
  `Shifty::PolicyConflict` when the pipeline is assembled.
- Exact strictness semantics (whether pipelines may *forbid* worker-level loosening)
  is an open question (§11.4); the initial implementation treats worker declarations
  as authoritative and pipeline policy as default-only.

### 5.4 Freezing the topology (companion change)

The same intentionality argument applies to the pipeline itself: `Worker#task=` and
`Worker#supply=` allow a fully assembled pipeline to be rewired mid-stream. This
change adds an optional `#freeze!` on the assembled chain so that "the pipeline you
composed is the pipeline that runs" can be a guarantee rather than a convention.
(Independent of handoff policy; included in the same major version.)

### 5.5 Optional worker naming for diagnostics

Workers gain an optional `name:` (in addition to existing tags) used purely in error
messages and diagnostics, so a `PolicyViolation` can say *which* of nine anonymous
workers raised.

---

## 6. Errors and Diagnostics

### 6.1 The problem

A developer changes a policy without changing task code (or vice versa), and the code
becomes *incorrect*. Raw `FrozenError`s from deep inside a task, surfacing in a test
run, do not point anywhere useful. The framework owns every task call site, so it can
do much better.

### 6.2 `Shifty::PolicyViolation`

```ruby
def perform_task(value)
  task.call(value)
rescue FrozenError => e
  raise PolicyViolation.new(
    worker:   self,          # includes name/tags for locating it
    policy:   effective_policy,
    receiver: e.receiver,    # the object the task tried to mutate
    value:    value,
    cause:    e              # never mask the original
  )
end
```

Key details:

- **`FrozenError#receiver`** identifies *which object* the task tried to mutate. This
  distinguishes "you mutated the handed-off value (or something reachable from it)"
  from an unrelated frozen-string-literal error in the task's own code. Heuristic:
  report whether `receiver.equal?(value)` or receiver appears reachable from `value`;
  when unclear, report both objects and let the developer judge.
- **Message content** (illustrative):

  > Worker `enricher` (tags: `[:etl]`) received its value under the `:frozen` handoff
  > policy, and its task attempted to mutate an instance of `Array`.
  >
  > Either make the task non-destructive — e.g. `map` instead of `map!`,
  > `value.with(...)`, `arr + [x]` — or declare a different policy on this worker:
  > `policy: :isolated` (task works on a private scratch copy) or `policy: :shared`
  > (raw reference; no protection).

- Unshareable-value failures at the handoff itself (IO, procs, singleton-methoded
  objects under `:frozen` or `:isolated`) raise a parallel
  `Shifty::UnshareableValue` error: *"this value cannot be frozen/copied; declare
  `:shared` on this worker, or restructure the value."*

### 6.3 The silent-loosening asymmetry

Error wrapping only catches motion in the *strict* direction. Moving **looser** —
`:frozen`/`:isolated` → `:shared` — fails silently: a task that was harmlessly
mutating its private copy (or that would have raised) now mutates the live shared
value. No exception will ever fire. This asymmetry must be documented prominently,
and it is the primary motivation for the mutation detector:

### 6.4 Mutation detector (opt-in diagnostic mode)

A development/test-only mode in which the framework hands each task a mutable deep
copy, then compares the copy before and after invocation (via `Marshal.dump`
comparison or recursive digest) and reports:

> Worker `enricher`'s task **mutates its input**. It is only correct under
> `:isolated` (mutation stays local) or `:shared` (mutation is intentional and
> observed downstream). It will raise under `:frozen`.

This surfaces mutation even when the current policy *permits* it — exactly the
information a developer needs **before** flipping a policy, not after. It also powers
the `not_to mutate_input` test matcher (§9.3). Never enabled in production paths
(it costs a deep copy per handoff plus comparison).

---

## 7. Coding Idioms Under `:frozen`

Documentation (README + a dedicated guide) should establish these patterns:

### 7.1 Copy-on-write instead of mutation

| Mutating (raises under `:frozen`) | Non-destructive equivalent |
|---|---|
| `str << "x"`, `str.upcase!` | `str + "x"`, `str.upcase` |
| `arr << x`, `arr.map!` | `arr + [x]`, `arr.map` |
| `hash[k] = v`, `hash.merge!` | `hash.merge(k => v)` |
| `obj.attr = v` | `obj.with(attr: v)` (see below) |

### 7.2 `Data.define` as the recommended value envelope

Ruby 3.2+ `Data` classes are immutable by construction and ship copy-on-update:

```ruby
Token = Data.define(:payload, :meta)

# in a worker task:
->(v) { v.with(payload: enrich(v.payload)) }
```

`#with` allocates one new outer object and copies member *references*; unchanged
members are structurally shared. This is safe precisely because everything is frozen.
If Shifty later grows an official work-item envelope (provenance, batch metadata),
`Data` is the substrate.

### 7.3 Mutable within, immutable between

Closure state remains fully mutable — that is Shifty's design and its selling point
for stateful workers, and nothing about it changes. Workers that *build* values
(sources; batch/trailing workers accumulating in closure scope) may mutate freely
during construction; the freeze happens at handoff. The framework thereby enforces
the functional-core boundary exactly where Shifty always drew it conceptually:

```ruby
source_worker do
  buffer = []                # closure state: mutable, private, fine
  while (line = io.gets)
    buffer << line           # construction: mutate freely
    handoff buffer.join if buffer.size == 10   # handoff: frozen from here on
  end
end
```

One consequence worth a doc callout: a builder that hands off an object and *keeps a
reference to it* (e.g. hands off `buffer` itself, then keeps appending) will raise on
the next append under `:frozen` — which is correct, and exactly the aliasing bug the
policy exists to catch. Hand off a snapshot (`buffer.dup`, `buffer.join`, `#with`)
when the builder intends to keep building.

### 7.4 Heavy accumulation: persistent data structures (optional)

For genuinely large collections under frequent update, `arr + [x]`'s O(n) pointer
copy can pinch. The **immutable-ruby** gem's persistent `Vector`/`Hash` offer
O(log n) structurally-shared updates. This is a documented optimization for users,
**not** a Shifty dependency.

---

## 8. Performance Analysis

### 8.1 Complexity per handoff

| Policy | CPU per handoff | Allocation per handoff |
|---|---|---|
| `:shared` | O(1) | none |
| `:frozen` | O(new objects since last freeze) — see 8.2 | none |
| `:isolated` | O(entire value graph) | entire value graph (GC pressure) |

Ordering: `:shared` ≤ `:frozen` (with copy-on-write idioms, delta-proportional)
≪ `:isolated` (whole-graph-proportional, per boundary). In practice the GC pressure
of `:isolated` — a full graph of garbage per worker per value — is often a bigger
real-world cost than the copy CPU itself.

### 8.2 Why `:frozen` amortizes

MRI marks objects shareable once `Ractor.make_shareable` has blessed them, and the
traversal short-circuits on already-shareable subgraphs. In a `:frozen` pipeline the
*first* handoff pays a full traversal of the value; every subsequent handoff
traverses only objects created since the previous one. Combined with copy-on-write
task code (which by definition creates only delta-sized new structure), per-boundary
freeze cost is proportional to the change, not the value.

### 8.3 `Ractor.shareable?` fast path (open design point)

If an incoming value is already shareable, it is deeply frozen and *nobody* can
mutate it — isolation is trivially satisfied without copying. `:isolated` could
exploit this and skip the copy. Wrinkle: the task then receives a frozen object where
it expected a mutable scratch copy. Options: (a) accept "you get either a mutable
copy or an already-immutable original" as the `:isolated` contract; (b) don't
optimize; (c) add an `:isolated_frozen` variant. Decision deferred pending benchmarks
(§13); initial implementation takes (b) for contract simplicity.

### 8.4 Benchmarks to produce before release

- `:shared` vs `:frozen` vs `:isolated` vs legacy `:hardened` (Marshal) across value
  shapes: small token, mid-size hash/array, large parsed document, deep nesting.
- First-handoff vs steady-state cost under `:frozen` (verify the amortization claim).
- GC statistics (allocations, minor/major GC counts) per policy.
- `Data#with` vs `make_shareable(copy: true)` for representative update patterns.

---

## 9. Testing Story

### 9.1 The parity problem

A pipeline runs `:frozen`; a unit test exercises the worker's raw proc
(`worker.task.call(input)`) with an ordinary mutable object. The test passes; the
pipeline raises. Three reinforcing moves close this gap:

### 9.2 Worker-level policy declarations win (§5.2)

Since the worker carries its policy, any test that runs the worker *through the
framework* automatically exercises production semantics. With `:frozen` as the
global default, the common case requires no test configuration at all.

### 9.3 Make the framework path the convenient path

```ruby
# Test harness — uses the worker's declared/effective policy by default
outputs = Shifty::Testing.run(worker, inputs: [a, b, c])

# Explicit override for policy-matrix testing
outputs = Shifty::Testing.run(worker, inputs: [a], policy: :frozen)
```

RSpec sugar:

```ruby
it_behaves_like "a policy-safe worker"    # runs task against deeply frozen input
expect(worker).not_to mutate_input        # built on the mutation detector (§6.4)
```

### 9.4 Test at the ceiling (monotonicity)

Policy safety is (almost) a one-way ratchet: a task correct on deeply frozen input is
correct under every policy; the reverse does not hold. Therefore the harness default
— and the documented guidance — is to test under `:frozen` unless the worker
explicitly declares mutation as part of its design. Consequences:

- Loosening a pipeline's policy can never break a ceiling-tested worker.
- Tightening is the only breaking direction, and tightening fails loudly with
  `PolicyViolation` diagnostics.

**Caveat (the "almost"):** `:isolated` hands the task a *copy*, so a worker
depending on object **identity** (rare; conceivable with identity-keyed caches)
behaves differently there. This is the one spot where strict-passing does not imply
lax-passing; document it.

---

## 10. Migration Guide (Breaking Changes)

### 10.1 What breaks

1. **Default behavior changes** from raw shared references (`:shared`) to deeply
   frozen references (`:frozen`). Any task that mutates its input raises
   `PolicyViolation` on first contact.
2. **Unshareable values** (IO handles, sockets, procs, lazy enumerators, objects
   with singleton methods) can no longer cross a default-policy boundary; they raise
   `UnshareableValue` at handoff. These pipelines must declare `:shared` on the
   affected workers.
3. **`:hardened` is deprecated**, mapped to `:isolated` with a deprecation warning
   for one major version, then removed. Semantics are preserved (deep private copy);
   the mechanism changes from Marshal round-trip to
   `make_shareable(copy: true)` where available. Note: the two mechanisms reject
   slightly different sets of objects (their failure sets overlap but are not
   identical) — this is covered by specs (§13) and called out in the CHANGELOG.

### 10.2 Migration paths, in order of preference

1. **Rewrite tasks non-destructively** (§7). Usually a small diff (`map!`→`map`,
   `<<`→`+`, `merge!`→`merge`); the `PolicyViolation` message names the object and
   the worker.
2. **Declare `:isolated`** on mutation-heavy workers not worth rewriting. Correctness
   preserved, cost localized to those workers.
3. **Declare `:shared`** where pass-by-reference is genuinely required (uncopyable
   values, intentional shared mutation). This restores today's exact semantics per
   worker.
4. **Blanket opt-out** for large legacy codebases:
   `Shifty.configure { |c| c.default_policy = :shared }` reproduces current behavior
   globally, letting teams migrate worker-by-worker.

### 10.3 Migration tooling

Run the mutation detector (§6.4) across an existing suite *before* upgrading: it
inventories which workers mutate input under the old default, i.e. exactly which
workers need path 1, 2, or 3.

---

## 11. Edge Cases and Open Questions

1. **Unshareable values under `:frozen`/`:isolated`** — raise `UnshareableValue`
   with guidance (declare `:shared`, or restructure). Should common cases (e.g.
   `Enumerator::Lazy`) get tailored messages? *(Nice-to-have.)*
2. **Object identity under `:isolated`** — copies break identity-based logic (§9.4).
   Documented; no mitigation planned.
3. **`shareable?` fast path for `:isolated`** — deferred; see §8.3.
4. **May a pipeline *forbid* worker-level `:shared`?** — e.g. a "strict Gang" for
   untrusted workers. Initial answer: no; worker contract wins (§5.2). Revisit if a
   concrete need appears.
5. **Frozen values and `#with`-less objects** — plain objects lack `#with`. Guidance:
   prefer `Data`; otherwise `clone(freeze: true)` + constructor patterns. Should
   Shifty ship a tiny `Shifty::Value` mixin? *(Probably not; stay unopinionated.)*
6. **Ractor future** — `:frozen`'s shareable values are exactly what Ractor
   boundaries require. This change is deliberately Ractor-*compatible* but
   Ractor-based workers remain out of scope. Fibers cannot cross Ractors; a
   Ractor-backed worker would be a distinct worker type in a future effort.
7. **Ruby version floor** — `Ractor.make_shareable` requires Ruby ≥ 3.0;
   `FrozenError#receiver` requires ≥ 2.7; `Data` idioms require ≥ 3.2. Proposal: set
   the gem's floor at 3.2 for this major version (aligns docs, `Data`, and mature
   `make_shareable` behavior). Marshal fallback then exists only for exotic
   platforms lacking Ractor support, if any are still targeted.

---

## 12. Out of Scope

- **Static/strong typing** (Sorbet, RBS): would extend data-space guarantees further,
  but is an orthogonal, separate developer choice. Nothing in this design should
  preclude it; `Data`-based envelopes are Sorbet-friendly if users go there.
- **Ractor-based parallel workers**: this change lays the groundwork (shareable
  values by default) but introduces no Ractors.
- **Persistent data structures as a dependency**: immutable-ruby remains a
  documented user-side optimization only.
- **Enforcing purity of closure state**: worker-internal state is intentionally
  mutable; that is Shifty's model. Only *handoffs* are governed.

---

## 13. Implementation Plan

**Phase 1 — mechanism**
- Handoff policy plumbing: worker attribute, pipeline default, global config,
  precedence resolution.
- `:frozen` (make_shareable), `:isolated` (make_shareable copy, Marshal fallback),
  `:shared` implementations at the handoff site.
- `PolicyViolation` / `UnshareableValue` wrapping with receiver heuristics and
  worker `name:` support.
- Specs: policy matrix × value shapes, including the Marshal-vs-make_shareable
  failure-set edge cases (procs, IO, singleton methods, lazy enumerators).

**Phase 2 — diagnostics & testing**
- Mutation detector mode.
- `Shifty::Testing.run` harness; RSpec shared examples and `mutate_input` matcher.
- Build-time `PolicyConflict` validation at composition.

**Phase 3 — performance & polish**
- Benchmark suite (§8.4); publish results in docs.
- Decide `shareable?` fast-path question (§8.3) from benchmark data.
- `#freeze!` for pipeline topology (§5.4).

**Phase 4 — release**
- Migration guide, CHANGELOG, README rewrite of the side-worker/hardened sections.
- Reconcile the concurrency documentation introduced by PR #26
  (`README.md` "Concurrency Model", `docs/use_cases.md`, and the thread-safety
  comments in `lib/shifty/worker.rb`): the interim edits there forward-reference
  this plan, but on release they must be updated from "planned" to shipped —
  fold copy-on-write idioms (§7) into `use_cases.md`'s examples, and confirm the
  single-threading/immutability boundary and Ractor-compatibility framing (§11.6)
  are stated as current behavior rather than future work.
- `:hardened` deprecation shim.
- Major version release.

---

## Appendix A — One-paragraph rationale (for README)

> Shifty workers are easy to reason about because each one is isolated; the values
> flowing *between* them were, until now, the un-governed part of the system. As of
> vNEXT, values are deeply frozen at every handoff by default. Workers that need a
> private scratch copy can declare `policy: :isolated`; workers that genuinely need
> shared mutable references can declare `policy: :shared`. Mutation bugs that used to
> surface as mysterious downstream corruption now either cannot happen or raise
> immediately at the worker responsible — with an error message that tells you
> exactly what to do about it.
