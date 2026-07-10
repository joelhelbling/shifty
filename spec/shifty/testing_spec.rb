require "spec_helper"
require "shifty/testing"

module Shifty
  RSpec.describe Testing do
    include DSL

    after { Shifty.reset_configuration! }

    describe ".run" do
      context "feeds inputs through the framework and collects outputs" do
        Given(:worker) { relay_worker { |v| v.upcase } }
        When(:outputs) { Testing.run(worker, inputs: ["a", "b", "c"]) }
        Then { expect(outputs).to eq(["A", "B", "C"]) }
      end

      context "exercises the worker's effective policy (parity with production)" do
        Given(:mutator) { Worker.new { |v| v && v << :x } }
        Then do
          expect { Testing.run(mutator, inputs: [[:a]]) }
            .to raise_error(PolicyViolation)
        end
      end

      context "a worker declaring :isolated runs under :isolated" do
        Given(:mutator) { Worker.new(policy: :isolated) { |v| v && v << :x } }
        When(:outputs) { Testing.run(mutator, inputs: [[:a]]) }
        Then { expect(outputs).to eq([[:a, :x]]) }
      end

      context "an explicit policy: override beats the worker's own declaration" do
        Given(:mutator) { Worker.new(policy: :shared) { |v| v && v << :x } }
        Then do
          expect { Testing.run(mutator, inputs: [[:a]], policy: :frozen) }
            .to raise_error(PolicyViolation)
        end
        And { expect(mutator.effective_policy).to eq(:shared) }
      end

      context "raises a diagnostic when a worker never passes the nil sentinel through" do
        Given(:worker) { Worker.new { |v| v.to_s } }
        Then do
          expect { Testing.run(worker, inputs: [:a], max_shifts: 50) }
            .to raise_error(Shifty::Error, /end-of-stream sentinel/)
        end
      end

      context "collects a non-1:1 output stream (filter) until end of stream" do
        Given(:evens) { filter_worker { |v| v.even? } }
        When(:outputs) { Testing.run(evens, inputs: [1, 2, 3, 4]) }
        Then { expect(outputs).to eq([2, 4]) }
      end
    end

    describe ".mutates_input?" do
      context "a mutating task is detected" do
        Given(:worker) { Worker.new(policy: :shared) { |v| v << :x } }
        Then { expect(Testing.mutates_input?(worker, [:a])).to be true }
      end

      context "a non-destructive task is not" do
        Given(:worker) { relay_worker { |v| v + [:x] } }
        Then { expect(Testing.mutates_input?(worker, [:a])).to be false }
      end

      context "detects mutation even when the worker's own policy would hide it" do
        Given(:worker) { side_worker(policy: :isolated) { |v| v << :boo } }
        Then { expect(Testing.mutates_input?(worker, [:a])).to be true }
      end
    end

    describe "opt-in loading" do
      Then { expect(File.read(File.expand_path("../../lib/shifty.rb", __dir__))).not_to match(%r{shifty/(testing|rspec)}) }
    end
  end
end
