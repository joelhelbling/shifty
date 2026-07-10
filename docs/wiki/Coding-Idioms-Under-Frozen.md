# Coding Idioms Under `:frozen`

Under the 0.6.0 default policy, every value a worker receives is deeply frozen (see [[Handoff-Policies]]). That sounds restrictive; in practice it asks for one habit: express change as *new values* rather than in-place edits. This page collects the idioms that make `:frozen` pleasant — copy-on-write equivalents, `Data.define` as the value envelope, the "mutable within, immutable between" rule for stateful workers, and the snapshot rule for builders.

## Copy-on-write instead of mutation

Most migrations are a one-character diff. The left column raises `PolicyViolation` under `:frozen`; the right column does the same job non-destructively:

| Mutating (raises under `:frozen`) | Non-destructive equivalent |
|---|---|
| `str << "x"`, `str.upcase!` | `str + "x"`, `str.upcase` |
| `arr << x`, `arr.map!` | `arr + [x]`, `arr.map` |
| `hash[k] = v`, `hash.merge!` | `hash.merge(k => v)` |
| `obj.attr = v` | `obj.with(attr: v)` (see below) |

There's a quiet synergy here: copy-on-write creates only delta-sized new structure, and `:frozen`'s freeze traversal only visits objects created since the last handoff. Each half makes the other cheap — see [[Performance]] for the numbers.

## `Data.define` as the value envelope

Ruby 3.2+ `Data` classes are immutable by construction and ship copy-on-update via `#with`:

```ruby
Token = Data.define(:payload, :meta)

# in a worker task:
enricher = relay_worker { |v| v.with(payload: enrich(v.payload)) }
```

`#with` allocates one new outer object and copies member *references*; unchanged members are structurally shared between old and new value. Structural sharing is only safe because the shared substructure is frozen — which under `:frozen` it always is. Freeze and `#with` aren't two features that happen to coexist; they're a matched set.

For plain objects without `#with`, prefer converting them to `Data`; failing that, `clone(freeze: true)` plus constructor patterns work. Shifty deliberately ships no value mixin of its own — stay unopinionated, bring your own envelope.

## Mutable within, immutable between

Closure state remains fully mutable — that is Shifty's design and its selling point for stateful workers, and nothing about it changed in 0.6.0. Workers that *build* values (sources; batch or trailing workers accumulating in closure scope) may mutate freely during construction. The freeze happens at handoff. The framework thereby enforces the functional-core boundary exactly where Shifty always drew it conceptually:

```ruby
reader = source_worker do
  buffer = []                 # closure state: mutable, private, fine
  while (line = io.gets)
    buffer << line            # construction: mutate freely
    if buffer.size == 10
      handoff buffer.join     # handoff: frozen from here on
      buffer = []
    end
  end
end
```

Note what got handed off: `buffer.join` — a fresh string, not the buffer itself. Which brings us to:

## The snapshot rule for builders

A builder that hands off an object and *keeps a reference to it* will raise on its next append under `:frozen`. The handoff freezes the live object; the builder's next `<<` hits a frozen array. This is correct — it is exactly the aliasing bug the policy exists to catch — but it means builders that intend to keep building must **hand off a snapshot**: `buffer.dup`, `buffer.join`, `value.with(...)`.

Shifty's own `trailing_worker` is the in-repo example. It accumulates a rolling window in a closure array and keeps mutating it across calls, so it hands off `trail.dup` — a snapshot — rather than the live array, which a downstream `:frozen` intake would otherwise freeze in place:

```ruby
# from lib/shifty/dsl.rb
# Hand off a snapshot: the builder keeps mutating `trail` across
# calls, and a downstream :frozen intake would freeze the live
# closure array in place.
trail.dup
```

If you write custom accumulating workers, follow the same rule.

## Heavy accumulation: persistent data structures

For genuinely large collections under frequent update, `arr + [x]`'s O(n) pointer copy can pinch. The [immutable-ruby](https://github.com/immutable-ruby/immutable-ruby) gem's persistent `Vector` and `Hash` offer O(log n) structurally-shared updates and play nicely with frozen handoffs. This is a documented user-side optimization, **not** a Shifty dependency — reach for it when profiling says so, not before.

## When the idioms don't fit

Some tasks are legitimately mutation-shaped — a third-party proc you don't control, a gnarly legacy transform not worth rewriting. Don't contort them; declare a policy on that worker instead: `policy: :isolated` for a private scratch copy, or `policy: :shared` when downstream really should observe the mutation. See [[Handoff-Policies]] for the trade-offs and [[Migration-Guide-0.6]] for choosing among them.
