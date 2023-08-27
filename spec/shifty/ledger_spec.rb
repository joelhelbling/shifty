require_relative "../../lib/shifty/ledger"

module Shifty
  RSpec.describe Ledger do
    # #[], #push, #last
    describe "#[]" do
      context "with initial value" do
        Given(:ledger) { Ledger[:foo] }
        Then { expect(ledger).to be_a(Shifty::Ledger) }
      end
      context "without initial value" do
        Then { expect { Ledger.new }.to raise_error(ArgumentError) }
      end
    end

    describe "#last" do
      Given(:ledger) { Ledger[:foo] }
      Then { ledger.last == :foo }
    end

    describe "#push" do
      Given(:ledger) { Ledger[:foo] }
      When { ledger.push :bar }
      Then { ledger.last == :bar }
    end

    describe "#pop" do
      Given(:ledger) { Ledger[:foo] }
      Given { ledger.push :bar }
      Given { ledger.push :baz }
      When { ledger.pop }
      Then { ledger.last == :bar }
    end

    describe "immutibility friendly" do
      Given(:ledger) { Ledger[:foo] }

      context "#push" do
        Given(:new_ledger) { ledger.push :bar }
        Then { expect(new_ledger).to be_a(Shifty::Ledger) }
      end

      context "#pop" do
        Given { ledger.push :bar }
        When(:new_ledger) { ledger.pop }
        Then { expect(new_ledger).to be_a(Shifty::Ledger) }
      end
    end
  end
end
