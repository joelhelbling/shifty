# Handoff policy benchmarks (spec §8.4). Manual-run, not CI:
#
#   bundle exec ruby benchmark/handoff_policies.rb
#
# Measures, per policy and value shape:
#   1. per-handoff cost of :shared / :frozen / :isolated / legacy :hardened
#      (Marshal), including :frozen's first-handoff vs steady-state cost
#      (the §8.2 amortization claim), and
#   2. the pure Marshal cost :isolated pays on an already-shareable
#      value — the copy a Ractor.shareable? fast path would skip
#      entirely (the §8.3 open question), and
#   3. allocation counts per policy (GC pressure).
#
# Results feed the wiki Performance page.

require "bundler/setup"
require "shifty"
require "benchmark/ips"

SHAPES = {
  "small token (string)" => -> { +"a token" },
  "mid array (100 strings)" => -> { Array.new(100) { |i| "item-#{i}" } },
  "mid hash (100 pairs)" => -> { Array.new(100) { |i| ["key-#{i}", "value-#{i}"] }.to_h },
  "large document (nested, ~5k nodes)" => -> {
    Array.new(50) do |i|
      {"id" => i, "name" => "record-#{i}",
       "tags" => Array.new(10) { |t| "tag-#{t}" },
       "children" => Array.new(10) { |c| {"idx" => c, "payload" => "data-#{i}-#{c}"} }}
    end
  },
  "deep nesting (500 levels)" => -> {
    (1..500).reduce([]) { |acc, i| [i, acc] }
  }
}

null_worker = Object.new
def null_worker.name = "bench"

def null_worker.tags = []

puts "Ruby #{RUBY_VERSION} — #{RUBY_PLATFORM}"
puts

SHAPES.each do |label, build|
  puts "=" * 72
  puts "SHAPE: #{label}"
  puts "=" * 72

  Benchmark.ips do |x|
    x.report(":shared") do
      Shifty::Policy::Shared.call(build.call, worker: null_worker)
    end
    x.report(":frozen (first handoff — fresh value each time)") do
      Shifty::Policy::Frozen.call(build.call, worker: null_worker)
    end
    frozen_value = Ractor.make_shareable(build.call)
    x.report(":frozen (steady state — already shareable)") do
      Shifty::Policy::Frozen.call(frozen_value, worker: null_worker)
    end
    x.report(":isolated (Marshal deep copy)") do
      Shifty::Policy::Isolated.call(build.call, worker: null_worker)
    end
    x.report(":isolated on already-frozen value (§8.3 fast-path question)") do
      Shifty::Policy::Isolated.call(frozen_value, worker: null_worker)
    end
    x.compare!
  end

  # Allocation pressure per single handoff
  value = build.call
  frozen_value = Ractor.make_shareable(build.call)
  {":shared" => [Shifty::Policy::Shared, value],
   ":frozen (steady)" => [Shifty::Policy::Frozen, frozen_value],
   ":isolated" => [Shifty::Policy::Isolated, value]}.each do |name, (policy, v)|
    GC.start
    before = GC.stat(:total_allocated_objects)
    100.times { policy.call(v, worker: null_worker) }
    allocated = GC.stat(:total_allocated_objects) - before
    puts format("allocations per handoff %-20s %8.1f", name, allocated / 100.0)
  end
  puts
end
