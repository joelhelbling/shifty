module Shifty
  RSpec.describe "supplier naming (issue #22)" do
    Given(:source) { Worker.new { :foo } }
    Given(:relay) { Worker.new { |value| value } }

    describe Worker do
      describe "#supplier and #supplier=" do
        When { relay.supplier = source }
        Then { relay.supplier == source }
        And  { relay.shift == :foo }
      end

      describe "constructor accepts supplier:" do
        Given(:worker) { Worker.new(supplier: source) { |value| value } }
        Then { worker.supplier == source }
      end

      describe "#supplier= refuses a source worker" do
        Given(:other_source) { Worker.new { :bar } }
        Then { expect { source.supplier = other_source }.to raise_error(WorkerError, /cannot accept a supplier/) }
      end

      describe "unready worker error message names the supplier" do
        Then { expect { relay.shift }.to raise_error(WorkerError, /has no supplier/) }
      end

      describe "deprecation warnings honor Warning[:deprecated]" do
        When(:warning) do
          capture_stderr do
            with_deprecation_warnings(enabled: false) { relay.supply = source }
          end
        end
        Then { warning.empty? }
        And  { relay.supplier == source }
      end

      describe "deprecated #supply reader" do
        Given { relay.supplier = source }
        When(:warning) { capture_stderr { with_deprecation_warnings { @result = relay.supply } } }
        Then { @result == source }
        And  { warning.match?(/\[shifty\].*#supply is deprecated.*#supplier/m) }
      end

      describe "deprecated #supply= writer" do
        When(:warning) { capture_stderr { with_deprecation_warnings { relay.supply = source } } }
        Then { relay.supplier == source }
        And  { warning.match?(/\[shifty\].*#supply= is deprecated.*#supplier=/m) }
      end

      describe "deprecated supply: constructor option" do
        When(:warning) { capture_stderr { with_deprecation_warnings { @worker = Worker.new(supply: source) { |value| value } } } }
        Then { @worker.supplier == source }
        And  { warning.match?(/\[shifty\].*supply:.*deprecated.*supplier:/m) }
      end
    end

    describe Gang do
      Given(:gang) { Gang.new([Worker.new { |value| value }, Worker.new { |value| value }]) }

      describe "#supplier and #supplier=" do
        When { gang.supplier = source }
        Then { gang.supplier == source }
        And  { gang.shift == :foo }
      end

      describe "deprecated #supply reader" do
        Given { gang.supplier = source }
        When(:warning) { capture_stderr { with_deprecation_warnings { @result = gang.supply } } }
        Then { @result == source }
        And  { warning.match?(/\[shifty\].*#supply is deprecated.*#supplier/m) }
      end

      describe "deprecated #supply= writer" do
        When(:warning) { capture_stderr { with_deprecation_warnings { gang.supply = source } } }
        Then { gang.supplier == source }
        And  { warning.match?(/\[shifty\].*#supply= is deprecated.*#supplier=/m) }
      end
    end

    describe "Policy::Supplier" do
      Then { Policy::Supplier.is_a?(Class) }
    end
  end
end
