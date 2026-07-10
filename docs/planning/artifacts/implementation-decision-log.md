# Implementation Decision Log: Handoff Immutability Policies

<!--
This file records every implementation decision committed while planning Handoff Immutability Policies.
Behavioral and implementation statements live in [../feature-implementation-plan.md](../feature-implementation-plan.md) —
this file captures the question, rationale, evidence, and rejected alternatives for each decision.
Round-by-round history lives in [implementation-iteration-history.md](implementation-iteration-history.md).
Source spec: [../handoff-immutability-policies.md](../handoff-immutability-policies.md).
Verbatim specialist outputs (referenced by A#/F#/test-# below): [.round1-specialist-outputs.md](.round1-specialist-outputs.md).

The D-N counter is shared across the trivial and full sections.
-->

## Trivial decisions

- D-14: `name:` kwarg retained (§5.5) — workers gain an optional `name:` for diagnostics alongside existing tags; kept per spec commitment and Joel's full-scope decision, no alternative worth debating. — Referenced in plan: Implementation Approach (Policy module and diagnostics).
- D-15: Seven-page wiki set — Home, Handoff-Policies, Coding-Idioms-Under-Frozen, Migration-Guide-0.6, Testing-Workers, Worker-Types, Performance; drafted under `docs/wiki/`, pushed to the GitHub wiki repo after merge; README slims to a quick tour plus links (Joel, R2). — Referenced in plan: Decomposition and Sequencing (PR 4).
- D-16: Drop `codeclimate-test-reporter` — the dev dep pins simplecov ≤ 0.13 (2016-era) and is effectively abandoned; removed while the gemspec is already open in PR 1 (junior-developer F8/C20). — Referenced in plan: Decomposition and Sequencing (PR 1).
- D-17: Real values, no doubles for policy behavior — policy specs assert on real frozen/copied values and raised errors, not on how the framework invokes `make_shareable`; matches the repo's rspec-given house style (test-engineer). — Referenced in plan: Testing Strategy.
- D-18: `shifty/testing` and `shifty/rspec` as separate opt-in requires — neither is loaded by `require "shifty"`; pure-Ruby harness split from the RSpec sugar (software-architect A6/C13). — Referenced in plan: Implementation Approach (testing layering), Decomposition and Sequencing (PR 2).
- D-19: Global configuration object — `Shifty::Configuration` with `default_policy` (built-in `:frozen`) plus `Shifty.configure`/`config`/`reset_configuration!`; API shape committed by Joel, effective policy memoized at first shift (software-architect A5/C12). — Referenced in plan: Implementation Approach (config), Decomposition and Sequencing (PR 1).
- D-20: `side_worker` accepts both `mode:` and `policy:` spellings — the lone `mode: :hardened` reference (dsl.rb:35) routes through `Policy.canonical` to `:isolated` with a one-time deprecation warning; both spellings pass through DSL option-splatting (software-architect A7, concurrency F17/C8). — Referenced in plan: Implementation Approach, Decomposition and Sequencing (PR 1).
- D-21: Mutation detector plus both RSpec constructs ship in PR 2 — the detector powers migration tooling, and the `mutate_input` matcher and `"a policy-safe worker"` shared example are both thin wrappers over it; kept per spec §9.3 and Joel's full-scope decision (junior-developer F12/C23 Disputed→resolved). — Referenced in plan: Implementation Approach (testing layering), Testing Strategy, Decomposition and Sequencing (PR 2).
- D-22: Release-phase repo sweep — remove stray `.gem` artifacts from repo root / `pkg`; confirm `Gemfile.lock` stays gitignored (conventional for a gem); housekeeping folded into PR 4 (junior-developer F11/C21). — Referenced in plan: Decomposition and Sequencing (PR 4).

## Full decisions

### D-1: Ingress-seam enforcement via PolicySupply decorator

- **Question:** Where in the worker runtime is a handoff policy applied so that every value crossing a worker boundary is governed exactly once?
- **Decision:** Apply policy at the **consuming worker's intake** (its supply pull), not at the producer's egress. Introduce a single `intake(value)` seam wrapping `worker.rb:64` (`value = supply&.shift`) and a thin `PolicySupply` decorator (responding to `#shift` as `intake(supply.shift)`) substituted as the task's 2nd argument at `worker.rb:66`. This covers all four `supply.shift` read sites (worker.rb:64; dsl.rb:55 filter, dsl.rb:86 batch, dsl.rb:122 trailing) with zero dsl.rb task-body changes. Producer-side `handoff`/`Fiber.yield` sites (source_worker, splitter_worker) get no instrumentation.
- **Rationale:** §6.2 names the *receiving* worker in the error, so policy is a property of how a worker receives its value. Every value a producer yields surfaces through some consumer's pull, so the consumer intake is the complete and minimal enforcement set; no value crosses twice, so `:isolated` never double-copies. Wrapping the supply once per worker satisfies the Rule of Three (three in-task `supply.shift` uses exist today) without touching task bodies. §7.3 aliasing is still caught: `make_shareable` freezes the actual object in place, so a producer that keeps mutating a handed-off object raises at the producer.
- **Evidence:** Independent convergence of software-architect A1 and concurrency-analyst F1–F4 (see [.round1-specialist-outputs.md](.round1-specialist-outputs.md)); enforcement sites enumerated at worker.rb:64/66, dsl.rb:55/86/122; discovery notes on the four `supply.shift` sites and producer-side `handoff`. C1–C3.
- **Rejected alternatives:**
  - Freeze at the single egress site (`Fiber.yield @task.call(...)`, worker.rb:66) — rejected because it misses in-task `supply.shift` in filter/batch/trailing workers and makes the *producer's* policy govern the boundary, contradicting §5.2 (worker declarations are the receiver's contract). Evidence: A1, F1.
  - Instrument `handoff`/`Fiber.yield` producer sites — rejected because `handoff` is a free DSL function with no access to the executing worker, and every internal yield already surfaces at the consumer's pull (double coverage, no gain). Evidence: F3.
- **Specialist owner:** software-architect (design), concurrency-analyst (handoff-site correctness).
- **Revisit criterion:** A future worker type that consumes values without a `supply.shift` intake (e.g. a Ractor-backed worker, §11.6) would need a new enforcement seam.
- **Dissent (if any):** None — specialists converged.
- **Driven by rounds:** R1.
- **Dependent decisions:** D-2, D-3, D-4, D-7, D-12, D-13.
- **Referenced in plan:** Implementation Approach (Architecture and Integration Points; Runtime Behavior), Decomposition and Sequencing (PR 1).

### D-2: Proactive IO detection for UnshareableValue

- **Question:** How is `UnshareableValue` (§6.2) raised for IO handles, sockets, and similar values, given the spec's stated assumption that `make_shareable` rejects them?
- **Decision:** Detect IO-like values **proactively** in the `:frozen` and `:isolated` apply paths and raise `Shifty::UnshareableValue` *before* calling `Ractor.make_shareable`. Do not rely on `make_shareable` raising. Proc and `Enumerator::Lazy` continue to raise naturally and are wrapped as `UnshareableValue`.
- **Rationale:** Empirical testing refutes spec §3.3/§10.1: `make_shareable` does **not** reject IO or singleton-methoded objects. It silently freezes a live IO in place — a process-wide side effect freezing a shared `$stdout`/logger/file handle for every reference in the process (materially worse than raising), and `copy: true` on an IO duplicates the fd, freezes the copy, and leaks one unusable fd per handoff. The spec's *intent* (UnshareableValue for uncopyable values) is preserved only if detection is proactive.
- **Evidence:** concurrency-analyst F7 (CRITICAL), F8, F9, F10 — empirical on Ruby 4.0.5; C4, C5. Re-verification on the Ruby 3.2 CI floor is a PR-1 spike task (see D-8).
- **Rejected alternatives:**
  - Trust the spec and let `make_shareable` reject IO — rejected: empirically false; it silently freezes live IO process-wide (F8) and leaks fds under `copy: true` (F9).
  - Reactive-only wrapping (catch whatever `make_shareable` raises) — rejected: for IO nothing is raised, so the damage is done silently before any wrap could fire (F7/F8).
- **Specialist owner:** concurrency-analyst.
- **Revisit criterion:** If the PR-1 spike on Ruby 3.2 finds `make_shareable` behavior differs materially from the 4.0.5 observations, the detection predicate and the `:isolated` failure-set table (test #19) are re-derived from the spike results.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** D-5, D-8, D-13.
- **Referenced in plan:** Implementation Approach (Runtime Behavior; empirical spike), RAID Log (assumptions/risks), Testing Strategy.

### D-3: Policy as three frozen singletons

- **Question:** What structure implements the three policies and their name resolution (including the `:hardened` alias)?
- **Decision:** A `Shifty::Policy` module holding three frozen singleton lambdas (`Frozen`, `Isolated`, `Shared`) behind `Policy.resolve(name)`, with a `TABLE` and an `ALIASES = {hardened: :isolated}` map; `canonical(name)` applies aliases and the `:hardened` deprecation warning. Not a class hierarchy, not a mixin. Each apply wraps `make_shareable`/Marshal failures (and the proactive IO check from D-2) as `UnshareableValue`.
- **Rationale:** Policy is a collaborator, not worker state (contrast the `Taggable` mixin), so a module of stateless strategies is the smallest fit. `resolve`/`ALIASES` gives one place for validation and the deprecation shim. Three concrete policies exist today — no speculative extensibility.
- **Evidence:** software-architect A2; C9. Existing `Taggable` mixin precedent in `lib/shifty/taggable.rb` (discovery notes).
- **Rejected alternatives:**
  - Class hierarchy of policy objects — rejected: no per-instance state to hold; adds ceremony over three stateless lambdas (A2).
  - Mixin on Worker (Taggable-style) — rejected: policy is a collaborator applied to values, not worker identity/state (A2).
- **Specialist owner:** software-architect.
- **Revisit criterion:** A fourth policy, or per-policy configuration state, would justice a richer object model.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** D-4, D-9, D-20.
- **Referenced in plan:** Implementation Approach (Policy module), Decomposition and Sequencing (PR 1).

### D-4: Two-attribute policy precedence

- **Question:** How is the worker > pipeline > global precedence (§5.2) represented and how does `.with_policy` propagate?
- **Decision:** Two nullable attributes on Worker — `@policy` (explicit contract) and `@pipeline_policy` (default) — resolved by `Policy.resolve(@policy || @pipeline_policy || Shifty.config.default_policy)`, memoized in `effective_policy`. `.with_policy(name)` validates eagerly, then walks the `.supply` chain upstream setting `pipeline_policy=` on each node; Gang fans `pipeline_policy=` out across its roster and `Gang#supply` returns `roster.first.supply` so the walk steps past a gang.
- **Rationale:** Two attributes let a nil `@policy` mean "undeclared" without a separate `declared?` flag or branching. There is no chain object for bare `|` chains — a pipeline is just the last worker (discovery notes) — so `.with_policy` must live on Worker and Gang and propagate via the supply chain. Workers do not know their consumer, so propagation walks upstream, not down.
- **Evidence:** software-architect A3; C9. Discovery notes: composition links workers by setting `supply`; no pipeline object exists; Gang is the only reifying container.
- **Rejected alternatives:**
  - Single `@policy` plus a `declared?` flag — rejected: forces branching everywhere the flag is read (A3).
  - Store policy by walking downstream to the consumer — rejected: workers hold no reference to their consumer, only to their supply (A3).
- **Specialist owner:** software-architect.
- **Revisit criterion:** A reified pipeline/chain object (if introduced later) would relocate `.with_policy` off Worker.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** D-19.
- **Referenced in plan:** Implementation Approach (precedence), Decomposition and Sequencing (PR 1).

### D-5: Consolidated error hierarchy

- **Question:** Where do the new and existing error classes live, and under what base?
- **Decision:** Consolidate errors into `lib/shifty/errors.rb` under a `Shifty::Error` base, with a `PolicyError` intermediate: `PolicyViolation < PolicyError` (attrs: worker, policy, receiver, value, cause) and `UnshareableValue < PolicyError` (attrs: worker, policy, value). Reparent existing `WorkerError`/`WorkerInitializationError` under `Shifty::Error` (source-compatible) and move `WorkerInitializationError` out of dsl.rb. No `PolicyConflict` class (see D-6).
- **Rationale:** A single error file with a common base is idiomatic and lets callers rescue `Shifty::Error` broadly or `PolicyError` narrowly. Reparenting is source-compatible because the existing classes keep their names.
- **Evidence:** software-architect A4; C10. `PolicyViolation`/`UnshareableValue` attribute lists from spec §6.2.
- **Rejected alternatives:**
  - Leave errors scattered across dsl.rb and worker.rb — rejected: no common ancestor for `rescue`, and the new policy errors need a home anyway (A4).
  - Include a `PolicyConflict` class — rejected: nothing to raise it (see D-6).
- **Specialist owner:** software-architect.
- **Revisit criterion:** A new error family (e.g. topology errors) would extend, not revise, this hierarchy.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** D-2, D-6.
- **Referenced in plan:** Implementation Approach (errors), Decomposition and Sequencing (PR 1).

### D-6: PolicyConflict dropped entirely

- **Question:** Does the plan ship a `PolicyConflict` class and build-time validation (spec §5.3, Phase 2)?
- **Decision:** Drop `PolicyConflict` entirely — no class, no validation.
- **Rationale:** The committed precedence rule (worker declarations authoritative, pipeline policy default-only, §11.4) leaves no violable rule to enforce, so there is nothing to raise. Joel (R2): "Since we're defaulting to frozen and allowing workers to opt out to something more permissive, we don't have a PolicyConflict... nothing to raise means no class, and we'll revisit later if we need to refine this."
- **Evidence:** User input, R2 (verbatim above). software-architect A4 and junior-developer F13/C11 independently flagged the class as vacuous.
- **Rejected alternatives:**
  - Define the class now, defer only the detection logic — rejected: a class with no raiser is dead code future agents would copy; Joel chose to drop it outright (R2).
  - Implement full build-time validation now — rejected: no rule exists to validate under the committed precedence semantics (A4, C11).
- **Specialist owner:** software-architect.
- **Revisit criterion:** A strict-Gang feature (§11.4) that lets a pipeline *forbid* worker-level loosening — that would introduce a violable rule and reopen the need for both the class and detection.
- **Dissent (if any):** None.
- **Driven by rounds:** R1 (flagged), R2 (decided).
- **Dependent decisions:** —.
- **Referenced in plan:** Implementation Approach (errors), Decomposition and Sequencing (PR 2 scope note), Deferred (YAGNI).

### D-7: trailing_worker aliasing fix in Phase 1

- **Question:** `trailing_worker` (dsl.rb:112–130) hands off its live closure `trail` array while continuing to `unshift`/`pop` it — under the `:frozen` default the next resume raises `FrozenError`. Where and how is this fixed?
- **Decision:** Fix the shipped worker in **PR 1** to hand off `trail.dup` (a snapshot), not the live array. batch/splitter/filter workers are confirmed safe as written and are **not** defensively changed.
- **Rationale:** This is exactly the aliasing bug class the policy exists to catch (§7.3), but it is in Shifty's own shipped DSL, so it must be fixed rather than merely documented. It travels with the mechanism (PR 1) because the `:frozen` default lands there. batch (fresh array + `.compact` new array), splitter (fresh local per call), and filter (no closure state) do not alias, so touching them would add risk for no benefit.
- **Evidence:** concurrency-analyst F13–F16 (trailing aliases at dsl.rb:125; others safe); junior-developer F4; test-engineer #11/#26; C7.
- **Rejected alternatives:**
  - Internally declare `trailing_worker policy: :shared` — rejected: masks the aliasing instead of fixing it, and denies trailing_worker users the `:frozen` guarantee (software-architect A7).
  - Leave it and document as a known break — rejected: it is first-party code; shipping a framework whose own DSL breaks under its own default is not acceptable.
- **Specialist owner:** concurrency-analyst.
- **Revisit criterion:** None expected; regression is guarded by test #26.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** D-12, D-13.
- **Referenced in plan:** Implementation Approach (Runtime Behavior), Decomposition and Sequencing (PR 1), Testing Strategy.

### D-8: Ruby 3.2 floor and CI matrix in Phase 1

- **Question:** Which PR owns `required_ruby_version >= 3.2` and the CI matrix rewrite?
- **Decision:** Land `required_ruby_version >= 3.2` in the gemspec and rewrite the CI matrix from `['2.6','2.7','3.0']` to `['3.2','3.3','3.4']` (plus refreshing stale `actions/checkout@v2` and the SHA-pinned setup-ruby) in **PR 1**, as a prerequisite to trusting any policy spec. The PR-1 spike re-verifies the D-2 `make_shareable` observations on the 3.2 floor.
- **Rationale:** The current matrix tests only Rubies *below* the new floor, so without this change every policy spec runs on unsupported, wrong-behavior Rubies. `Data` idioms (§7.2) and mature `make_shareable` need ≥ 3.2. This is a release blocker that gates the correctness of everything else in PR 1.
- **Evidence:** junior-developer F7, F9; C15; resolved by evidence/aggregation (OQ-4). CI matrix at `.github/workflows/ruby.yml:21`; gemspec lacks `required_ruby_version` (discovery notes).
- **Rejected alternatives:**
  - Put CI/gemspec changes in the Phase-4 release PR — rejected: policy specs in PRs 1–3 would run on unsupported Rubies with different `make_shareable`/Data behavior, invalidating them (F7, OQ-4).
  - A separate prerequisite PR before PR 1 — rejected: adds a fifth PR for a change that naturally belongs with the mechanism it enables; one-PR-per-phase is the committed shape.
- **Specialist owner:** junior-developer (raised); PM (sequencing).
- **Revisit criterion:** None; floor is fixed for the 0.6.0 line.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** D-2.
- **Referenced in plan:** Decomposition and Sequencing (PR 1), RAID Log.

### D-9: :hardened deprecation horizon

- **Question:** In 0.x terms, when is the deprecated `:hardened` option removed?
- **Decision:** `:hardened` is **deprecated in 0.6.0** (mapped to `:isolated` with a one-time warning via `Policy.canonical`) and **removed at 1.0.0**. Docs state "deprecated in 0.6.0, removed in 1.0.0."
- **Rationale:** The spec speaks of "one major version, then removed," which is undefined in a pre-1.0 line. Joel (R2) set the concrete horizon: keep the shim through the 0.x series and drop it at the 1.0.0 boundary, which is the natural major-version break.
- **Evidence:** User input, R2. junior-developer F1/C16 flagged the undefined 0.x horizon (OQ-1).
- **Rejected alternatives:**
  - Remove at the next minor (0.7.0) — rejected: too aggressive for a deprecation users have not yet seen; Joel chose the 1.0.0 boundary (R2).
  - Keep indefinitely — rejected: leaves a dead alias and the Marshal-divergence caveat (C5) live forever (R2).
- **Specialist owner:** software-architect (shim), PM (horizon).
- **Revisit criterion:** If 1.0.0 slips materially, re-confirm the removal still rides that release.
- **Dissent (if any):** None.
- **Driven by rounds:** R1 (flagged), R2 (decided).
- **Dependent decisions:** D-20.
- **Referenced in plan:** Implementation Approach, Decomposition and Sequencing (PR 1), Deferred/Migration notes.

### D-10: Manual-run benchmark directory

- **Question:** Where do the §8.4 benchmarks live, how are they run, and what dependency do they add?
- **Decision:** A `benchmark/` directory with `benchmark-ips` as a **dev** dependency, **manual-run** (not in CI), results published to the wiki Performance page. Benchmarks land in **PR 3**. If they contradict the §8.2 amortization claim, the `:frozen` default is revisited before release.
- **Rationale:** The §8.2 amortization claim is load-bearing for choosing `:frozen` as default but is uncited until measured. Running benchmarks in CI would make the suite slow and flaky for a measurement that is consulted occasionally; manual runs with published results fit a gem with no perf SLO.
- **Evidence:** junior-developer F10/C19/C6; resolved by aggregation (OQ-6). No benchmark tooling exists today (discovery notes).
- **Rejected alternatives:**
  - CI-run benchmarks — rejected: slow/flaky CI for an occasionally-consulted measurement; replaced by manual runs + published results (OQ-6).
  - Skip benchmarks — rejected: the default-policy choice rests on the unvalidated §8.2 claim (F10); measurement is required before release.
- **Specialist owner:** junior-developer (raised); PM (sequencing).
- **Revisit criterion:** Benchmarks show `:frozen` amortization does not hold on representative value shapes → revisit the default before 0.6.0 ships (RAID R1).
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** —.
- **Referenced in plan:** Decomposition and Sequencing (PR 3), RAID Log, Deferred (YAGNI) (CI-run benchmarks).

### D-11: Version bump and CHANGELOG in Phase-4 PR

- **Question:** When do the version bump to 0.6.0 and the CHANGELOG entry land, given one PR per phase and shipped-but-unreleased `main` between PRs?
- **Decision:** The version bump (`lib/shifty/version.rb` → 0.6.0) and the CHANGELOG entry land in the **Phase-4 (release) PR**, together with the README rewrite, wiki drafts, PR-26 doc reconciliation, and the gem build. `main` may carry unreleased behavior between PRs 1–3.
- **Rationale:** Nothing is published until Joel builds and pushes 0.6.0, so `main` being shipped-but-not-yet-released between phase PRs is harmless; deferring the version/CHANGELOG to the release PR keeps a single coherent release note rather than four partial bumps. This is a process-convention call, not an evidenced one.
- **Evidence:** junior-developer F5/C17 (Anecdotal — process convention); reframed the release-timing question, resolved by convention (OQ-5).
- **Rejected alternatives:**
  - Bump version per-phase PR — rejected: four intermediate versions for one logical release; no publish happens between them so the bumps carry no signal (F5).
- **Specialist owner:** junior-developer (reframed); Joel (publishes).
- **Revisit criterion:** If any phase PR is released independently, that PR must carry its own bump/CHANGELOG.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** —.
- **Referenced in plan:** Decomposition and Sequencing (PR 4), Definition of Done.

### D-12: Terminal output governance out of scope

- **Question:** The value the last worker's `shift` returns to user code crosses no consumer intake and is therefore un-governed by any policy. Is that a gap to close?
- **Decision:** Leave terminal output un-governed; document it in the wiki/migration guide. No framework mechanism wraps the final `shift`.
- **Rationale:** Spec §2 scopes policies to *worker boundaries*; the terminal caller is not a worker, so there is no boundary to govern. The one shipped aliasing hazard at the terminal (trailing_worker) is removed by D-7, so the residual is documentation only.
- **Evidence:** aggregator synthesis from A1/F1; C25; resolved by evidence against spec §2 scoping.
- **Rejected alternatives:**
  - Govern terminal output by wrapping the final `shift` — rejected: the terminal caller is outside the worker-boundary model the policies are scoped to (§2); adding a special case there would be scope creep with no boundary to protect (C25).
- **Specialist owner:** software-architect.
- **Revisit criterion:** If a use case emerges where user code downstream of the last worker needs the same mutation guarantees, reconsider a terminal policy.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** —.
- **Referenced in plan:** Implementation Approach (Runtime Behavior), Decomposition and Sequencing (PR 4, wiki).

### D-13: Equivalence-class test matrix

- **Question:** How much of the policy × value-shape space does the test suite cover?
- **Decision:** Cover **8 load-bearing equivalence-class cells** (not the full 3×10 cartesian), plus 5 boundary-case behaviors (#9–13), 4 error-diagnostic contracts (#14–17), the deprecation shim + a table-driven `:isolated` failure-set spec (#18–19), 4 meta-tests for the testing harness (#20–23), and 3 existing-spec migrations (#24–26). The `:isolated` failure-set table (#19) cannot be authored from the spec and requires an implementation spike on the target Ruby first (per D-2). Real values throughout, no doubles.
- **Rationale:** The full cartesian is mostly redundant — String behaves as Array, nil × isolated/shared is trivial — so equivalence classes give the same confidence at a fraction of the maintenance. The failure-set table must be spiked because the spec's rejection claims are empirically wrong (D-2).
- **Evidence:** test-engineer full prioritized plan; C22. Existing specs that break under `:frozen`: dsl_spec.rb:149–164, 166–174, 317–341.
- **Rejected alternatives:**
  - Full 3×10 policy × value-shape cartesian — rejected: String duplicates Array, nil cells are trivial passthrough; equivalence classes cover the load-bearing behavior with far less to maintain (test-engineer).
- **Specialist owner:** test-engineer.
- **Revisit criterion:** A new value shape with distinct freeze/copy behavior (outside the existing equivalence classes) adds a cell.
- **Dissent (if any):** None.
- **Driven by rounds:** R1.
- **Dependent decisions:** —.
- **Referenced in plan:** Testing Strategy, Decomposition and Sequencing (all PRs).
