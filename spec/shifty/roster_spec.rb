module Shifty
  RSpec.describe Roster do
    include DSL

    Given(:source) { source_worker((:a..:z).map(&:to_s)) }
    Given(:plusser) { relay_worker { |v| v + "+" } }
    Given(:tilda_er) { relay_worker { |v| v + "~" } }

    When(:roster) { described_class.new workers }

    describe "#responds_to?" do
      Given(:workers) { [] }
      Then do
        expect(roster).to respond_to(:push, :"<<", :first, :last)
      end
    end

    describe "#push" do
      Given(:workers) { [source, plusser] }

      When { roster.push tilda_er }

      Then { roster.last == tilda_er }
      And  { roster.last.supply == plusser }
    end

    describe "#pop" do
      Given(:workers) { [source, plusser, tilda_er] }

      When(:popped) { roster.pop }

      Then { roster.last == plusser }
      Then { popped == tilda_er }
      Then { expect(popped).to_not be_ready_to_work }
    end

    describe "#shift" do
      Given(:workers) { [source, plusser, tilda_er] }

      When(:shifted) { roster.shift }

      Then { shifted == source }
      Then { expect(roster.first).to_not be_ready_to_work }
    end

    describe "#unshift" do
      context "when first work is not a source" do
        Given(:workers) { [plusser, tilda_er] }

        When { roster.unshift source }

        Then { roster.workers == [source, plusser, tilda_er] }
        Then { expect(plusser).to be_ready_to_work }
        Then { plusser.supply == source }
      end

      context "when first worker is a source" do
        Given(:new_source) { source_worker((:z..:a).map(&:to_s)) }
        Given(:workers) { [source, plusser, tilda_er] }

        Then { expect { roster.unshift new_source }.to raise_error(/cannot accept a supply/) }
      end
    end
  end
end
