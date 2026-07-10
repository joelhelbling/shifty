# Feature Implementation Plan: Handoff Immutability Policies

<!-- Ship the three-policy handoff model (`:frozen` default, `:isolated`, `:shared`) plus diagnostics, a test harness, topology `#freeze!`, and migration docs as shifty 0.6.0, across four reviewed PRs (one per spec phase) branched from main; the plan ends at a built gem and release prep, which Joel publishes himself. -->

## Source Specification

- **Feature specification:** [handoff-immutability-policies.md](../handoff-immutability-policies.md)
- **Specification decision log:** none — the spec came directly from the maintainer and has no plan-a-feature companions (no decision-log, team-findings, or feature-technical-notes files). The planning iteration artifacts for this implementation live in [artifacts/](artifacts/): [implementation-decision-log.md](artifacts/implementation-decision-log.md) and [implementation-iteration-history.md](artifacts/implementation-iteration-history.md), with verbatim specialist outputs in [artifacts/.round1-specialist-outputs.md](artifacts/.round1-specialist-outputs.md).
- **Specification open items this plan resolves:** §8.3 shareable? fast path (deferred), §11.4 strict-Gang / PolicyConflict (dropped), §11.5 Shifty::Value mixin (deferred), §11.7 Ruby floor (3.2).

## Outcome

When this plan is executed, shifty 0.6.0 exists as a built gem in which every value crossing a worker boundary is governed by a handoff policy — `:frozen` by default (deeply frozen, zero-copy), with `:isolated` (private deep copy) and `:shared` (raw reference) opt-outs declarable at worker, pipeline, and global levels. Policy violations raise `Shifty::PolicyViolation` naming the offending worker; uncopyable values raise `Shifty::UnshareableValue`. A `Shifty::Testing` harness and opt-in RSpec sugar let unit tests exercise workers under production policy. Assembled pipelines can be locked with `#freeze!`. The gem's own DSL (`trailing_worker`, `side_worker`) works under the new default, the CI matrix and Ruby floor match the shipped behavior, and a seven-page wiki plus a slimmed README document it.

## Context

- **Driving constraint:** A committed 0.6.0 release that carries a breaking default-behavior change (`:shared` → `:frozen`). The change is the point of the release; it must land coherently with migration docs before Joel publishes.
- **Stakeholders:** Joel (maintainer — owns the API, reviews each PR, builds and publishes the gem); existing shifty users (must migrate mutation-heavy tasks; served by loud/local errors and a migration guide); future contributors (served by the ingress-seam design keeping enforcement in one place).
- **Future-state concern:** The `:frozen` default rests on the §8.2 amortization claim, which is unvalidated until PR-3 benchmarks; and the IO/`make_shareable` behavior is verified only on Ruby 4.0.5, re-verified on the 3.2 CI floor in a PR-1 spike. Both are tracked risks (see RAID Log).
- **Out-of-scope boundary:** Static typing (Sorbet/RBS), Ractor-based parallel workers, persistent-data-structure dependencies, and enforcing purity of closure state — all per spec §12. Terminal (post-last-worker) output is deliberately un-governed ([D-12](artifacts/implementation-decision-log.md#d-12-terminal-output-governance-out-of-scope)).

## Team Composition and Participation

Medium team; deterministic aggregation was used in place of live PM facilitation (the spec-maturity gate never tripped). Full round detail: [artifacts/implementation-iteration-history.md](artifacts/implementation-iteration-history.md).

| Specialist | Status | Key Input |
|------------|--------|-----------|
| `project-manager` | Coordinator | Synthesized this plan; classified decisions; ran the YAGNI gate. |
| `software-architect` | Active | Ingress-seam design, Policy module, precedence, error hierarchy, testing layering (A1–A7). |
| `concurrency-analyst` | Active | Handoff-site correctness; empirically refuted the spec's `make_shareable` IO claims; trailing_worker aliasing; `#freeze!` mechanics (F1–F22). |
| `test-engineer` | Active | Prioritized equivalence-class test plan, failure-set spike, existing-spec migration (8 cells + boundaries + meta-tests). |
| `junior-developer` | Reframer | 0.x version translation, CI/gemspec gaps, benchmark home, wiki split, PolicyConflict vacuity (F1–F13). |
| `information-architect` | Handoff (PR 4) | Not yet engaged; consult during wiki authoring (see Specialist Handoffs). |

## Implementation Approach

### Architecture and Integration Points

Policy is enforced at the **consuming worker's intake**, not the producer's egress ([D-1](artifacts/implementation-decision-log.md#d-1-ingress-seam-enforcement-via-policysupply-decorator)). A single `intake(value)` seam wraps the primary pull at `worker.rb:64`, and a thin `PolicySupply` decorator (responding to `#shift` as `intake(supply.shift)`) is substituted as the task's 2nd argument at `worker.rb:66`. This covers all four `supply.shift` read sites (worker.rb:64; dsl.rb:55 filter, dsl.rb:86 batch, dsl.rb:122 trailing) with zero dsl.rb task-body changes; producer-side `handoff`/`Fiber.yield` sites need no instrumentation because every yielded value surfaces at a consumer's pull ([D-1](artifacts/implementation-decision-log.md#d-1-ingress-seam-enforcement-via-policysupply-decorator)). The `intake`/`perform_task`/`policy_supply` sketch is in [artifacts/.round1-specialist-outputs.md](artifacts/.round1-specialist-outputs.md) (A1) and is not inlined here.

New files land as: **PR 1** — `lib/shifty/errors.rb`, `lib/shifty/policy.rb`, `lib/shifty/configuration.rb`; **PR 2** — `lib/shifty/testing.rb`, `lib/shifty/rspec.rb`. `lib/shifty.rb` requires the runtime files; `shifty/testing` and `shifty/rspec` are separate opt-in requires, neither loaded by `require "shifty"` ([D-18](artifacts/implementation-decision-log.md#trivial-decisions)).

Errors consolidate into `lib/shifty/errors.rb` under a `Shifty::Error` base with a `PolicyError` intermediate; `PolicyViolation` and `UnshareableValue` descend from it, and existing `WorkerError`/`WorkerInitializationError` are reparented source-compatibly ([D-5](artifacts/implementation-decision-log.md#d-5-consolidated-error-hierarchy)). No `PolicyConflict` class ships ([D-6](artifacts/implementation-decision-log.md#d-6-policyconflict-dropped-entirely)).

### Policy module and diagnostics

`Shifty::Policy` is a module of three frozen singleton lambdas (`Frozen`, `Isolated`, `Shared`) behind `Policy.resolve(name)`, with `ALIASES = {hardened: :isolated}` and a `canonical` step that emits the `:hardened` deprecation warning — not a class hierarchy, not a mixin ([D-3](artifacts/implementation-decision-log.md#d-3-policy-as-three-frozen-singletons)). Workers gain an optional `name:` used purely in diagnostics ([D-14](artifacts/implementation-decision-log.md#trivial-decisions)). `PolicyViolation` carries worker/policy/receiver/value/cause and uses the `receiver.equal?(value)` / reachable / unrelated heuristic (§6.2) to attribute the mutation.

### Precedence and configuration

Precedence (worker > pipeline > global, §5.2) is two nullable Worker attributes — `@policy` (contract) and `@pipeline_policy` (default) — resolved by `@policy || @pipeline_policy || Shifty.config.default_policy` and memoized ([D-4](artifacts/implementation-decision-log.md#d-4-two-attribute-policy-precedence)). Because bare `|` chains have no chain object (a pipeline is just the last worker), `.with_policy` walks the `.supply` chain upstream, and Gang fans out across its roster ([D-4](artifacts/implementation-decision-log.md#d-4-two-attribute-policy-precedence)). Global config is a `Shifty::Configuration` object with `default_policy` (built-in `:frozen`) plus `Shifty.configure`/`config`/`reset_configuration!` ([D-19](artifacts/implementation-decision-log.md#trivial-decisions)).

### Runtime behavior and IO detection

At each intake the effective policy is applied: `:frozen` calls `Ractor.make_shareable`, `:isolated` copies (`make_shareable(copy: true)`, Marshal fallback), `:shared` passes through. Crucially, IO-like values are detected **proactively** and raise `UnshareableValue` *before* `make_shareable` is called ([D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue)): the spec's claim that `make_shareable` rejects IO is empirically wrong — it silently freezes live IO process-wide, and `copy: true` leaks a file descriptor. Proc and `Enumerator::Lazy` raise naturally and are wrapped. The shipped `trailing_worker` is fixed in PR 1 to hand off `trail.dup` rather than its live closure array ([D-7](artifacts/implementation-decision-log.md#d-7-trailing_worker-aliasing-fix-in-phase-1)); batch/splitter/filter workers are confirmed safe and left untouched. Terminal output (the last worker's return to user code) is un-governed by design ([D-12](artifacts/implementation-decision-log.md#d-12-terminal-output-governance-out-of-scope)).

`#freeze!` (PR 3) locks assembled topology; its motivation is `supply=`/Roster rewiring, not the non-existent `Worker#task=` the spec cites. It must (a) force-materialize each worker's lazy default task before freezing, (b) freeze the Roster `@workers` array, and (c) for bare `|` chains, walk the `.supply` chain to discover members (F19–F21).

### Testing layering and the empirical spike

`shifty/testing` (pure Ruby) provides `Shifty::Testing.run(worker, inputs:, policy:)` and the `mutates_input?` detector; `shifty/rspec` provides the `"a policy-safe worker"` shared example and the `mutate_input` matcher, both thin wrappers over the detector ([D-21](artifacts/implementation-decision-log.md#trivial-decisions)). Because the `:isolated`/`:frozen` failure sets diverge from the spec's stated behavior, the failure-set table must be **spiked on the target Ruby before its spec is authored** ([D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue), [D-13](artifacts/implementation-decision-log.md#d-13-equivalence-class-test-matrix)).

## Decomposition and Sequencing

Four PRs, one per spec phase, each branched from main and reviewed before merge. Each PR's definition of done includes `standardrb` clean and the full RSpec suite green.

| # | Work Unit (PR) | Delivers | Depends On | Verification |
|---|-----------|----------|------------|--------------|
| 1 | **Phase 1 — mechanism** | Ingress seam + `PolicySupply` ([D-1](artifacts/implementation-decision-log.md#d-1-ingress-seam-enforcement-via-policysupply-decorator)); `Policy` module ([D-3](artifacts/implementation-decision-log.md#d-3-policy-as-three-frozen-singletons)); precedence + `.with_policy` ([D-4](artifacts/implementation-decision-log.md#d-4-two-attribute-policy-precedence)); `errors.rb` ([D-5](artifacts/implementation-decision-log.md#d-5-consolidated-error-hierarchy)); global config ([D-19](artifacts/implementation-decision-log.md#trivial-decisions)); proactive IO detection + PR-1 spike ([D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue)); `trailing_worker` fix + `side_worker` `mode:`/`policy:` shim ([D-7](artifacts/implementation-decision-log.md#d-7-trailing_worker-aliasing-fix-in-phase-1), [D-20](artifacts/implementation-decision-log.md#trivial-decisions)); **`required_ruby_version >= 3.2` + CI matrix rewrite + codeclimate removal** ([D-8](artifacts/implementation-decision-log.md#d-8-ruby-32-floor-and-ci-matrix-in-phase-1), [D-16](artifacts/implementation-decision-log.md#trivial-decisions)) | — | Policy × shape cells 1–8, boundary 9–13, failure-set table #19 (post-spike), migration specs #24–26; suite green on 3.2/3.3/3.4 |
| 2 | **Phase 2 — diagnostics & testing** | Mutation detector; `Shifty::Testing.run`; RSpec shared example + `mutate_input` matcher ([D-21](artifacts/implementation-decision-log.md#trivial-decisions)); separate requires ([D-18](artifacts/implementation-decision-log.md#trivial-decisions)). **No `PolicyConflict`** ([D-6](artifacts/implementation-decision-log.md#d-6-policyconflict-dropped-entirely)) | 1 | Error-diagnostic tests #14–17; meta-tests #20–23 |
| 3 | **Phase 3 — performance & `#freeze!`** | `benchmark/` dir + `benchmark-ips` dev dep, manual-run ([D-10](artifacts/implementation-decision-log.md#d-10-manual-run-benchmark-directory)); `#freeze!` with F19–F21 scope | 1 | Benchmark results captured; `#freeze!` specs (lazy-task materialize, roster freeze, supply-chain walk) |
| 4 | **Phase 4 — release** | Version bump → 0.6.0 + CHANGELOG ([D-11](artifacts/implementation-decision-log.md#d-11-version-bump-and-changelog-in-phase-4-pr)); README rewrite + seven wiki drafts ([D-15](artifacts/implementation-decision-log.md#trivial-decisions)); PR-26 doc reconciliation (README Concurrency Model, docs/use_cases.md, worker.rb comments); spec-text correction for IO ([D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue)); repo sweep ([D-22](artifacts/implementation-decision-log.md#trivial-decisions)); gem build | 1, 2, 3 | Docs consistent (planned → shipped); benchmark results published to wiki Performance page; `gem build` succeeds |

## RAID Log

### Risks

| ID | Risk | Likelihood | Severity | Blast Radius | Reversibility | Owner | Mitigation |
|----|------|------------|----------|--------------|---------------|-------|------------|
| R1 | §8.2 amortization claim is unvalidated until PR-3 benchmarks; if `:frozen` cost is not delta-proportional on real value shapes, the default choice is wrong | Low | High | The headline default of the release | Reversible pre-release (change default) | junior-developer / Joel | Benchmarks in PR 3 ([D-10](artifacts/implementation-decision-log.md#d-10-manual-run-benchmark-directory)); if contradicted, revisit default before 0.6.0 ships |
| R2 | `make_shareable`/IO behavior verified only on Ruby 4.0.5, not the 3.2 floor | Medium | Medium | IO-detection predicate + `:isolated` failure-set table | Reversible (adjust predicate) | concurrency-analyst | PR-1 spike re-verifies on 3.2 CI before the failure-set spec is authored ([D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue), [D-8](artifacts/implementation-decision-log.md#d-8-ruby-32-floor-and-ci-matrix-in-phase-1)) |
| R3 | Breaking the default (`:shared` → `:frozen`) surprises every mutation-heavy task | High (that it fires) | Low (well-behaved) | All existing user pipelines | Reversible per-worker/global (`:shared`) | Joel | Loud/local `PolicyViolation`; migration guide with four ordered paths; blanket opt-out documented; small user base |

### Assumptions

| ID | Assumption | What Changes If Wrong | Verifier | Status |
|----|------------|-----------------------|----------|--------|
| A1 | Every value crossing a boundary surfaces through some consumer's `supply.shift` (so intake enforcement is complete) | Producer-side sites would need instrumentation | concurrency-analyst F1–F4 | Verified (F1–F4, four sites enumerated) |
| A2 | `make_shareable(copy: true)` short-circuits (returns same object) for already-frozen Data | `:frozen`→`:isolated` steady-state cost model changes | concurrency-analyst F11 | Verified (F11, structural) — CPU amortization still Runtime-only (R1) |
| A3 | `main` may carry shipped-but-unreleased behavior between phase PRs | Would force per-PR version bumps | junior-developer F5 | Verified (nothing publishes until Joel builds 0.6.0) |

### Issues

| ID | Issue | Owner | Next Step |
|----|-------|-------|-----------|
| I1 | Spec §3.3/§10.1 text asserts `make_shareable` rejects IO — factually wrong; ships as-is until PR 4 | PM / Joel | Correct spec + README/wiki text in PR 4 ([D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue)) |

### Dependencies

| ID | Dependency | Owner | Status |
|----|------------|-------|--------|
| Dep1 | `benchmark-ips` dev dependency (PR 3) | junior-developer | Not yet added |
| Dep2 | GitHub wiki repo exists to receive `docs/wiki/` drafts (PR 4) | Joel | To confirm at PR 4 |

## Testing Strategy

Sourced from test-engineer's prioritized plan ([D-13](artifacts/implementation-decision-log.md#d-13-equivalence-class-test-matrix)); rspec-given Given/When/Then house style, `raise_error(/regex/)` plus structured accessor checks, real values, no doubles ([D-17](artifacts/implementation-decision-log.md#trivial-decisions)).

- **Observable behaviors to test:**
  - **8 equivalence-class cells:** `:frozen`×Array (`<<` raises, `receiver.equal?(value)`); `:frozen`×Hash-containing-Array (nested mutation raises, receiver reachable-not-equal); `:frozen`×Data (`.with` returns new frozen instance); `:frozen`×nil (passthrough); `:isolated`×Array (copy mutates freely, upstream unaffected); `:isolated`×Data-with-mutable-member; `:shared`×Array (mutation visible to holders); `:shared`×IO (passes through, no error).
  - **Boundary cases 9–13:** mid-task `supply.shift` under upstream `:frozen` raises like primary intake (#9); splitter under `:frozen` freezes *each* yielded part, not just the last (#10, deliberately fails a naive single-site impl); `trailing_worker` under `:frozen` must not raise + prior trail unaffected (#11, proves `trail.dup`); `side_worker(policy: :isolated)` original unmutated (#12); criteria-bypass value still policy-applied (#13).
  - **Error diagnostics 14–17:** `PolicyViolation` accessors + message (#14); receiver heuristic three branches — equal / reachable / unrelated (#15); `UnshareableValue` guidance text matches `/:shared/` (#16); `violation.cause` is the original `FrozenError` (#17).
  - **Shim & failure sets 18–19:** `:hardened`→`:isolated` equivalence + one-time deprecation warning (capture `$stderr`, no ActiveSupport) (#18); table-driven `:isolated` failure set over IO/Proc/Lazy/singleton — **authored only after the PR-1 spike** (#19, [D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue)).
  - **Meta-tests 20–23:** `Testing.run` uses the worker's effective policy by default (#20); explicit `policy:` override (#21); `mutate_input` matcher passes/fails against real workers (#22); shared example passes known-good/fails known-bad (#23).
- **Existing-suite migration (#24–26):** dsl_spec.rb:149–164 (`v << :boo`) rewritten non-destructively + a companion `policy: :shared` spec preserving old behavior (the migration worked example); dsl_spec.rb:166–174 `:hardened` context retargeted to `:isolated` with a thin shim regression; dsl_spec.rb:317–341 trailing_worker passes once `trail.dup` lands, plus a new aliasing assertion. worker/gang/roster specs are mutation-free and pass unmodified.
- **Test doubles posture:** none for policy behavior — assert on real frozen/copied values and raised errors, not on `make_shareable` invocation ([D-17](artifacts/implementation-decision-log.md#trivial-decisions)).
- **Test levels:** unit (policy cells, diagnostics, DSL workers), integration (framework-run harness meta-tests), migration (existing-spec rewrites doubling as worked examples).
- **Skipped with triggers:** nil×isolated/shared, String cells (same class as Array), full cartesian, identity-keyed-cache caveat, shareable? fast path, PolicyConflict tests — all per [D-13](artifacts/implementation-decision-log.md#d-13-equivalence-class-test-matrix) / Deferred.

## Definition of Done

- [ ] Every value crossing a worker boundary is policy-governed at intake; `:frozen` is the built-in default ([D-1](artifacts/implementation-decision-log.md#d-1-ingress-seam-enforcement-via-policysupply-decorator), [D-19](artifacts/implementation-decision-log.md#trivial-decisions)).
- [ ] Mutation under `:frozen` raises `PolicyViolation` naming the worker; IO under `:frozen`/`:isolated` raises `UnshareableValue` without freezing live handles ([D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue)).
- [ ] Policy declarable at worker/pipeline/global with worker > pipeline > global precedence ([D-4](artifacts/implementation-decision-log.md#d-4-two-attribute-policy-precedence)).
- [ ] Shipped DSL works under `:frozen`: trailing_worker fixed, side_worker `:hardened` shim warns once ([D-7](artifacts/implementation-decision-log.md#d-7-trailing_worker-aliasing-fix-in-phase-1), [D-20](artifacts/implementation-decision-log.md#trivial-decisions), [D-9](artifacts/implementation-decision-log.md#d-9-hardened-deprecation-horizon)).
- [ ] `Shifty::Testing.run`, `mutate_input` matcher, and `"a policy-safe worker"` shared example ship as opt-in requires ([D-18](artifacts/implementation-decision-log.md#trivial-decisions), [D-21](artifacts/implementation-decision-log.md#trivial-decisions)).
- [ ] `#freeze!` locks topology (lazy-task materialize, roster freeze, supply-chain walk).
- [ ] Benchmarks run and published; §8.2 amortization confirmed or the default revisited ([D-10](artifacts/implementation-decision-log.md#d-10-manual-run-benchmark-directory)).
- [ ] CI green on 3.2/3.3/3.4; gemspec floor `>= 3.2`; codeclimate dep removed ([D-8](artifacts/implementation-decision-log.md#d-8-ruby-32-floor-and-ci-matrix-in-phase-1), [D-16](artifacts/implementation-decision-log.md#trivial-decisions)).
- [ ] Version bumped to 0.6.0, CHANGELOG written, README slimmed, seven wiki pages drafted, PR-26 docs reconciled ([D-11](artifacts/implementation-decision-log.md#d-11-version-bump-and-changelog-in-phase-4-pr), [D-15](artifacts/implementation-decision-log.md#trivial-decisions)).
- [ ] `standardrb` clean and full suite green on each PR; gem builds. Post-ship owner: Joel (publishes with 2FA).

## Specialist Handoffs for Implementation

- **`information-architect`** — dispatch during PR 4 wiki authoring; needs the seven approved page titles ([D-15](artifacts/implementation-decision-log.md#trivial-decisions)), the coding-idioms table (§7), and the migration paths (§10) to structure findability and progressive disclosure across Home/Handoff-Policies/Coding-Idioms/Migration/Testing/Worker-Types/Performance.
- **`han` code review** — dispatch per PR before merge; needs the PR diff and this plan's Definition-of-Done row for that phase.
- **`concurrency-analyst`** — dispatch for the PR-1 spike to re-verify `make_shareable`/IO behavior on Ruby 3.2 before the failure-set spec (#19) is authored; needs the 3.2 CI environment ([D-2](artifacts/implementation-decision-log.md#d-2-proactive-io-detection-for-unshareablevalue)).

## Deferred (YAGNI)

### PolicyConflict class + build-time validation
- **Why deferred:** Dropped by user (R2) — with worker-declarations authoritative and pipeline policy default-only, no violable rule exists to raise; a class with no raiser is dead code future agents would copy ([D-6](artifacts/implementation-decision-log.md#d-6-policyconflict-dropped-entirely)).
- **Reopen when:** A strict-Gang feature (§11.4) that lets a pipeline forbid worker-level loosening.
- **Source:** software-architect A4 / junior-developer C11; decided by Joel, R2.

### `shareable?` fast path / `:isolated_frozen` variant (§8.3)
- **Why deferred:** Committed decision (option b) for contract simplicity; premature optimization with no measured copy-cost evidence.
- **Reopen when:** §8.4 benchmarks show material copy cost that the fast path would remove.
- **Source:** spec §8.3; software-architect Deferred list.

### `Shifty::Value` mixin (§11.5)
- **Why deferred:** The spec itself recommends staying unopinionated; single speculative abstraction with no concrete demand.
- **Reopen when:** An official work-item envelope feature (provenance/batch metadata) lands, making `Data` the substrate.
- **Source:** spec §11.5; software-architect Deferred list.

### Fiber-local "current worker" registry (concurrency F6)
- **Why deferred:** `self` is available everywhere the registry would be consulted; abstraction with no use.
- **Reopen when:** Task bodies need self-introspection beyond what `self` provides.
- **Source:** concurrency-analyst F6.

### `Shifty::TopologyFrozenError` wrapper (F22)
- **Why deferred:** Plain `FrozenError` from post-`freeze!` `supply=` is already unambiguous; a wrapper adds a class for no clarity gain.
- **Reopen when:** Migration feedback shows users are confused by the raw `FrozenError`.
- **Source:** concurrency-analyst F22.

### Full 3×10 policy × value-shape cartesian
- **Why deferred:** Replaced by 8 equivalence-class cells — String duplicates Array, nil cells are trivial passthrough; simpler version satisfies the same evidence ([D-13](artifacts/implementation-decision-log.md#d-13-equivalence-class-test-matrix)).
- **Reopen when:** A value shape with distinct freeze/copy behavior outside the existing classes appears.
- **Source:** test-engineer.

### CI-run benchmarks
- **Why deferred:** Replaced by a manual-run `benchmark/` directory with results published to the wiki — CI runs would be slow/flaky for an occasionally-consulted measurement; simpler version satisfies the same evidence ([D-10](artifacts/implementation-decision-log.md#d-10-manual-run-benchmark-directory)).
- **Reopen when:** A performance regression that only continuous measurement would catch becomes a real concern.
- **Source:** junior-developer C19 / OQ-6.

## Open Items

None blocking. All seven R1 Open Questions resolved (OQ-4/5/6/7 by evidence-aggregation; OQ-1/2/3 by Joel in R2). The plan ends at a built gem and release prep; Joel publishes 0.6.0 himself with 2FA — publication is deliberately outside this plan's scope, not an unresolved item.

## Summary

- **Outcome delivered:** shifty 0.6.0, built and release-ready, with `:frozen`-default handoff immutability, diagnostics, a test harness, topology freeze, and migration docs, across four reviewed PRs.
- **Team size:** 5 specialists (PM, software-architect, concurrency-analyst, test-engineer, junior-developer; information-architect on PR-4 handoff) — see [artifacts/implementation-iteration-history.md](artifacts/implementation-iteration-history.md)
- **Rounds of facilitation:** 2 — see [artifacts/implementation-iteration-history.md](artifacts/implementation-iteration-history.md)
- **Decisions committed:** 22 — see [artifacts/implementation-decision-log.md](artifacts/implementation-decision-log.md)
- **Decisions settled by evidence:** 15 — see [artifacts/implementation-decision-log.md](artifacts/implementation-decision-log.md)
- **Decisions settled by junior-developer reframing:** 1 — see [artifacts/implementation-decision-log.md](artifacts/implementation-decision-log.md)
- **Decisions settled by user input:** 6 — see [artifacts/implementation-decision-log.md](artifacts/implementation-decision-log.md)
- **Rejected alternatives recorded:** 24 — see [artifacts/implementation-decision-log.md](artifacts/implementation-decision-log.md)
- **Open items remaining:** 0 blocking
- **Recommendation:** Ship as planned — begin PR 1 (mechanism + Ruby 3.2 floor + PR-1 IO spike).
