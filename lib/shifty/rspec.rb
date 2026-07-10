require "shifty/testing"

# Opt-in RSpec sugar for testing Shifty workers under handoff policies.
# `require "shifty/rspec"` from your spec_helper; assumes RSpec is loaded.

RSpec::Matchers.define :mutate_input do |input|
  match do |worker|
    Shifty::Testing.mutates_input?(worker, input)
  end

  failure_message do |worker|
    "expected the worker's task to mutate its input #{input.inspect}, but it did not"
  end

  failure_message_when_negated do |worker|
    "expected the worker's task not to mutate its input, but it mutated " \
      "#{input.inspect}. It is only correct under policy :isolated (mutation " \
      "stays local) or :shared (mutation is intentional); it will raise under :frozen."
  end
end

# Runs the worker through the framework against deeply frozen input —
# the strictest policy — proving the task is non-destructive and therefore
# correct under every policy (§9.4, "test at the ceiling").
#
# Expects `worker` and `safe_input` to be defined with `let`.
RSpec.shared_examples "a policy-safe worker" do
  it "processes a deeply frozen input without raising" do
    expect {
      Shifty::Testing.run(worker, inputs: [safe_input], policy: :frozen)
    }.not_to raise_error
  end

  it "does not mutate its input" do
    expect(worker).not_to mutate_input(safe_input)
  end
end
