require "spec_helper"
require "shifty/rspec"

module Shifty
  RSpec.describe "shifty/rspec sugar" do
    include DSL

    describe "the mutate_input matcher" do
      context "detects a mutating worker" do
        Given(:worker) { side_worker(policy: :shared) { |v| v << :boo } }
        Then { expect(worker).to mutate_input([:a]) }
      end

      context "passes a non-destructive worker" do
        Given(:worker) { relay_worker { |v| v + [:x] } }
        Then { expect(worker).not_to mutate_input([:a]) }
      end
    end

    describe %(the "a policy-safe worker" shared example) do
      context "with a non-destructive worker" do
        it_behaves_like "a policy-safe worker" do
          let(:worker) { Shifty::Worker.new { |v| v&.to_s } }
          let(:safe_input) { [:a] }
        end
      end
    end
  end
end
