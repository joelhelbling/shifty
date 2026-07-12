require "spec_helper"

module Shifty
  RSpec.describe "#freeze! topology locking" do
    include DSL

    describe "on a composed worker chain" do
      Given(:source) { source_worker [1, 2, 3] }
      Given(:doubler) { relay_worker { |v| v * 2 } }
      Given(:pipeline) { source | doubler }

      context "returns the receiver, chainable" do
        Then { expect(pipeline.freeze!).to be pipeline }
      end

      context "a frozen pipeline still runs" do
        Given { pipeline.freeze! }
        Then { pipeline.shift == 2 }
        And { pipeline.shift == 4 }
      end

      context "rewiring the frozen tail raises" do
        Given { pipeline.freeze! }
        Given(:interloper) { source_worker [:x] }
        Then { expect { pipeline.supplier = interloper }.to raise_error(FrozenError) }
      end

      context "the walk freezes upstream workers too" do
        Given { pipeline.freeze! }
        Then { expect(source).to be_frozen }
        And { expect(doubler).to be_frozen }
      end

      context "a worker relying on the lazy default task still runs after freeze!" do
        Given(:passthrough) { Worker.new(supplier: source_worker([:a])) }
        Given(:frozen_pipeline) { passthrough.freeze! }
        Then { frozen_pipeline.shift == :a }
      end
    end

    describe "on a Gang" do
      Given(:a) { relay_worker { |v| v + 1 } }
      Given(:b) { relay_worker { |v| v * 10 } }
      Given(:gang) { Gang[a, b] }
      Given(:pipeline) { source_worker([1, 2]) | gang }

      context "a frozen gang still runs" do
        Given { pipeline.freeze! }
        Then { pipeline.shift == 20 }
      end

      context "appending to a frozen gang raises" do
        Given { pipeline.freeze! }
        Then { expect { gang.append(relay_worker { |v| v }) }.to raise_error(FrozenError) }
      end

      context "roster members are frozen" do
        Given { pipeline.freeze! }
        Then { expect(a).to be_frozen }
        And { expect(b).to be_frozen }
      end

      context "the walk continues past the gang to upstream workers" do
        Given(:upstream) { source_worker [5] }
        Given(:tail) { relay_worker { |v| v } }
        Given(:chain) { upstream | gang | tail }
        Given { chain.freeze! }
        Then { expect(upstream).to be_frozen }
        And { expect(tail).to be_frozen }
      end
    end
  end
end
