# Implementation Iteration History: Handoff Immutability Policies

<!--
This file records how the implementation plan evolved across discussion rounds.
Committed decisions live in [implementation-decision-log.md](implementation-decision-log.md)
and the primary plan lives in [../feature-implementation-plan.md](../feature-implementation-plan.md).
Source spec: ../handoff-immutability-policies.md (design doc; no plan-a-feature artifacts,
so no T# technical notes exist and the T#-contradiction classification does not apply).
-->

## R1: Parallel specialist review

- **Specialists engaged:** concurrency-analyst, software-architect, test-engineer, junior-developer (project-manager reserved for synthesis; deterministic aggregation used per skill).
- **New input provided:** Initial feature spec (`../handoff-immutability-policies.md`), discovery notes (`.discovery-notes.md`), and Joel's nine committed decisions (0.6.0, all four phases, Ruby ≥ 3.2 floor, API shape, one PR per phase, wiki via docs/wiki/, :hardened→:isolated, no shareable? fast path, Joel publishes gem).

- **Claim ledger:**

| # | Claim | Raised by | Category | State |
|---|-------|-----------|----------|-------|
| C1 | Policy must be enforced at the consumer's intake (supply pull), via a supply-wrapping decorator substituted at worker.rb:64 and as the task's 2nd arg at worker.rb:66; covers all four `supply.shift` sites (worker.rb:64, dsl.rb:55, dsl.rb:86, dsl.rb:122) with zero dsl.rb task-body changes | concurrency-analyst (F1–F4), software-architect (A1) — independent convergence | design | Evidenced |
| C2 | Producer-side `handoff`/`Fiber.yield` sites (source_worker, splitter_worker) need no instrumentation — every yielded value surfaces through the consumer's pull | concurrency-analyst (F3), software-architect (A1) | design | Evidenced |
| C3 | criteria-bypass path (worker.rb:68) is automatically covered by intake-side enforcement | concurrency-analyst (F5) | edge-case | Evidenced |
| C4 | **Spec §3.3/§10.1 are factually wrong**: `make_shareable` does NOT reject IO or singleton-methoded objects — it silently freezes live IO in place (process-wide side effect) and `copy: true` on IO leaks a file descriptor. Only Proc and Enumerator::Lazy raise. UnshareableValue must be raised proactively for IO-like values | concurrency-analyst (F7–F9), empirical on Ruby 4.0.5 | assumption-refuted | Evidenced (re-verify on 3.2 CI) |
| C5 | Marshal-vs-make_shareable divergence includes a silent-behavior-change case: singleton-methoded values failed loudly under :hardened (Marshal) but silently succeed under :isolated (make_shareable) — migration guide must call this out separately | concurrency-analyst (F10) | edge-case | Evidenced |
| C6 | §8.2 already-shareable short-circuit confirmed structurally (copy: true returns same object for frozen Data); CPU amortization claim still needs §8.4 benchmarks | concurrency-analyst (F11), junior-developer (F10) | ambiguity | Evidenced (partial) |
| C7 | trailing_worker (dsl.rb:112–130) hands off its live closure array and breaks under :frozen — required Phase-1 shipped-code fix (`trail.dup`); batch/splitter/filter workers confirmed safe as written | concurrency-analyst (F13–F16), junior-developer (F4), test-engineer (#11) | edge-case | Evidenced |
| C8 | side_worker `mode: :hardened` (dsl.rb:35,40–41) maps to policy: :isolated with deprecation warning via Policy.canonical; shim must accept both `mode:` and `policy:` spellings | concurrency-analyst (F17), software-architect (A7), test-engineer (#18) | design | Evidenced |
| C9 | Policy strategies as three frozen singletons in `Shifty::Policy` with `resolve(name)` + ALIASES; not a class hierarchy, not a mixin; precedence as two nullable attributes (@policy contract, @pipeline_policy default) resolved by `||`-chain; `.with_policy` walks the supply chain upstream, Gang fans out to roster | software-architect (A2, A3) | design | Evidenced |
| C10 | Errors consolidate into lib/shifty/errors.rb under Shifty::Error base with PolicyError intermediate; existing WorkerError/WorkerInitializationError reparented (source-compatible) | software-architect (A4) | design | Evidenced |
| C11 | `PolicyConflict` build-time validation has nothing to enforce: committed decision (worker wins, pipeline default-only, §11.4) leaves no violable rule. Define the class, defer the detection | software-architect (A4), junior-developer (F13) | YAGNI-candidate | Evidenced |
| C12 | Global config: `Shifty::Configuration` object + `Shifty.configure`/`config`/`reset_configuration!`; effective policy memoized at first shift | software-architect (A5) | design | Evidenced |
| C13 | shifty/testing (pure Ruby) and shifty/rspec (opt-in) as separate requires, neither loaded by `require "shifty"` | software-architect (A6) | design | Evidenced |
| C14 | §5.4 cites a `Worker#task=` writer that does not exist; #freeze! motivation must be restated (supply= + Roster rewiring). #freeze! must (a) force-materialize lazy @task first, (b) freeze Roster @workers array, (c) walk .supply chain for bare `\|` chains | concurrency-analyst (F18–F21), junior-developer (F2) | assumption-refuted + design | Evidenced |
| C15 | CI matrix (.github/workflows/ruby.yml:21) tests only 2.6/2.7/3.0 — zero supported Rubies under the 3.2 floor; matrix rewrite + required_ruby_version are a Phase-1 prerequisite, plus stale actions | junior-developer (F7, F9) | assumption-refuted | Evidenced |
| C16 | "major version" language throughout spec needs 0.x translation; :hardened removal horizon ("one major version, then removed") is undefined in 0.x terms | junior-developer (F1) | spec-level | Evidenced |
| C17 | main will be shipped-but-undocumented-inconsistent between phase PRs; version bump + CHANGELOG should land in the Phase-4 (release) PR | junior-developer (F5) | ambiguity | Anecdotal (process convention) |
| C18 | Wiki page list, audience, and README/wiki split undefined; docs/wiki/ doesn't exist; information-architect input recommended at Phase 4 | junior-developer (F6) | spec-level | Evidenced |
| C19 | Benchmark suite has no home/run-mode/dependency decision; §8.2 amortization is load-bearing-but-uncited for the :frozen default | junior-developer (F10) | ambiguity | Evidenced |
| C20 | codeclimate-test-reporter dev dep pins simplecov ≤ 0.13 (2016-era), effectively abandoned — drop while touching gemspec | junior-developer (F8) | edge-case | Evidenced |
| C21 | Stray .gem files in repo root / pkg; Gemfile.lock gitignored (conventional for a gem) — release-phase sweep item | junior-developer (F11) | polish | Evidenced |
| C22 | Test plan: 8 load-bearing policy×shape equivalence-class cells (not full cartesian), 4 boundary-case behaviors, 4 error-diagnostic contracts, deprecation shim + empirical failure-set table (spike required before authoring), meta-tests for Testing.run/matcher/shared example, 3 existing specs break under :frozen default (dsl_spec.rb:151, 166–174, 317–341) and double as migration worked examples; real values throughout, no doubles | test-engineer (full plan) | test-coverage | Evidenced |
| C23 | Mutation detector + both RSpec constructs sized as large Phase-2 surface; matcher and shared example both ship vs one | junior-developer (F12) vs spec §9.3 commitment | YAGNI-candidate | Disputed (resolved: spec + user committed all; both are thin wrappers over the detector) |
| C24 | name: kwarg (§5.5) vs existing tags for diagnostics | junior-developer (F13) | YAGNI-candidate | Resolved by spec commitment (§5.5, user decision: full scope) |
| C25 | Terminal-output governance: under intake-side enforcement, the value returned by the LAST worker's `shift` to user code crosses no consumer intake and is un-governed | aggregator (from A1/F1 synthesis) | edge-case | Resolved by evidence: spec §2.1 scopes policies to worker boundaries; terminal caller is not a worker. Document in wiki/migration guide; trailing_worker fix (C7) removes the one shipped aliasing hazard |

- **Open Questions raised:**
  - OQ-1 (from C16): What is the :hardened removal horizon in 0.x terms? → escalate to user with recommendation "removed at 1.0.0".
  - OQ-2 (from C11): Defer PolicyConflict detection logic (class only) — deviation from spec §13 Phase 2 scope? → escalate to user with recommendation "defer with reopening trigger".
  - OQ-3 (from C18): Wiki page list and README/wiki split → propose page list to user.
  - OQ-4 (from C15): Which phase owns CI matrix + required_ruby_version? → resolved by evidence/aggregation: Phase 1 PR (prerequisite for trusting policy specs on supported Ruby).
  - OQ-5 (from C17): Version bump + CHANGELOG timing → resolved by convention: Phase-4 release PR; main may carry unreleased behavior between PRs since nothing is published until 0.6.0.
  - OQ-6 (from C19): Benchmark home/run-mode → resolved by aggregation: `benchmark/` directory, benchmark-ips as dev dependency, manual-run (not CI), results published to wiki Performance page; if results contradict §8.2 the default is revisited before release (risk logged).
  - OQ-7 (from C4): Spec correction for make_shareable rejection set → resolved by evidence: spec *intent* (UnshareableValue for IO) is preserved via proactive IO detection in Policy application; spec doc + README/wiki text corrected in Phase 4. Empirical re-verification on Ruby 3.2 CI is a Phase-1 spike task.
- **Spec-maturity tags:** plan-level: C1–C15, C17, C19–C25 (majority); spec-level: C16 (junior-developer), C18 (junior-developer). 2 spec-level findings from 1 specialist — **gate NOT tripped** (threshold: ≥5 from ≥3 specialists). No T# notes exist, so T#-contradiction does not apply.
- **Resolution source:** OQ-4, OQ-5, OQ-6, OQ-7, C25 — evidence/deterministic aggregation. OQ-1, OQ-2, OQ-3 — user input (batched escalation, see R2).
- **Decisions produced:** D-1, D-2, D-3, D-4, D-5, D-7, D-8, D-10, D-11, D-12, D-13 (full); D-14, D-16, D-17, D-18, D-19, D-20, D-21, D-22 (trivial). D-6 and D-9 flagged this round (C11→OQ-2, C16→OQ-1) but decided in R2.
- **Changed in plan:** Implementation Approach; Decomposition and Sequencing; RAID Log; Testing Strategy; Definition of Done; Deferred (YAGNI).
- **Next-step recommendation (deterministic):** Blocked pending user input on OQ-1/OQ-2/OQ-3 (single batched escalation); all other findings resolve to synthesis inputs. No re-engagement handoffs required — specialist outputs converge with no disputes surviving aggregation.

## R2: User escalation (batched OQ-1/OQ-2/OQ-3)

- **Specialists engaged:** none — direct user escalation with recommendations, per Step 6.
- **New input provided:** Joel's answers to the three surviving Open Questions.
- **Claim ledger:** no new claims; three resolutions:
  - OQ-1 → `:hardened` deprecated in 0.6.0, **removed at 1.0.0**. Docs state "deprecated in 0.6.0, removed in 1.0.0".
  - OQ-2 → **PolicyConflict dropped entirely** (no class, no validation). Joel: "Since we're defaulting to frozen and allowing workers to opt out to something more permissive, we don't have a PolicyConflict... nothing to raise means no class, and we'll revisit later if we need to refine this." Reopening trigger: a strict-Gang feature (§11.4) that can forbid worker-level loosening.
  - OQ-3 → seven-page wiki set approved as proposed (Home, Handoff-Policies, Coding-Idioms-Under-Frozen, Migration-Guide-0.6, Testing-Workers, Worker-Types, Performance); README keeps the quick tour and links into the wiki.
- **Open Questions raised:** none.
- **Spec-maturity tags:** n/a (no new findings).
- **Resolution source:** OQ-1, OQ-2, OQ-3 — user input (verbatim above).
- **Decisions produced:** D-6 (PolicyConflict dropped), D-9 (:hardened removed at 1.0.0), D-15 (seven-page wiki set).
- **Changed in plan:** Implementation Approach; Decomposition and Sequencing (PR 2 PolicyConflict removed, PR 4 wiki set); Deferred (YAGNI); Definition of Done.
- **Next-step recommendation (deterministic):** Go to synthesis — zero unresolved Open Questions, zero pending handoffs, round produced no new findings.
