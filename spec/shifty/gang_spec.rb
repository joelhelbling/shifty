module Shifty
  RSpec.describe Gang do
    include DSL

    Given(:source) { source_worker((:a..:z).map(&:to_s)) }
    Given(:b_appender) { relay_worker { |v| v + "_b" } }
    Given(:c_appender) { relay_worker { |v| v + "_c" } }

    When(:gang) { described_class[*workers] }

    context "covers Worker API" do
      Then do
        expect(subject).to respond_to(
          :ready_to_work?, :shift,
          :supply, :supply=,
          :supplies, :"|" # rubocop:disable Lint/SymbolConversion
        )
      end
    end

    describe "#ready_to_work?" do
      context "with no source" do
        Given(:workers) { [b_appender, c_appender] }

        Then { expect(gang).to_not be_ready_to_work }
      end

      context "with an internal source" do
        Given(:workers) { [source, b_appender, c_appender] }

        Then { expect(gang).to be_ready_to_work }
      end

      context "with external source" do
        context "supplied to the first worker" do
          Given { source | b_appender }
          Given(:workers) { [b_appender, c_appender] }

          Then { expect(gang).to be_ready_to_work }
        end

        context "supplied to the gang" do
          Given(:workers) { [b_appender, c_appender] }

          When { gang.supply = source }

          Then { expect(gang).to be_ready_to_work }
        end
      end
    end

    describe "#| (a.k.a. #supplies)" do
      Given(:workers) { [source, b_appender] }

      When { gang | c_appender }

      context "gets gang as source" do
        Then { expect(c_appender.shift).to eq("a_b_c") }
      end
    end

    context "#append" do
      Given(:workers) { [source, b_appender] }
      Given(:d_appender) { relay_worker { |v| v + "_d" } }

      When { gang | c_appender }
      When { gang.append d_appender }

      context "adds a worker to the end of the gang's roster" do
        Then { expect(c_appender.shift).to eq("a_b_d_c") }
      end
    end

    context "normal usage" do
      Given(:workers) { [source, b_appender, c_appender] }

      Then { expect(gang.shift).to eq("a_b_c") }
    end

    describe ":tags" do
      Given(:workers) { [source, b_appender, c_appender] }

      context "no tags" do
        Then { expect(gang.tags).to eq([]) }
      end

      context "initialization" do
        When(:gang) { described_class.new(workers, tags: tag_arg) }

        context "a single tag" do
          Given(:tag_arg) { :foo }
          Then { expect(gang.tags).to eq([:foo]) }
        end

        context "multiple tags" do
          Given(:tag_arg) { [:foo, :bar] }
          Then { expect(gang.tags).to eq([:foo, :bar]) }
        end
      end

      context "by assignment" do
        When { gang.tags = tag_arg }

        context "a single tag" do
          Given(:tag_arg) { :foo }
          Then { expect(gang.tags).to eq([:foo]) }
        end

        context "multiple tags" do
          Given(:tag_arg) { [:foo, :bar] }
          Then { expect(gang.tags).to eq([:foo, :bar]) }
        end
      end

      describe "#has_tag?" do
        Given(:gang) { described_class.new workers }
        When { gang.tags = [:foo] }

        Then { expect(gang).to have_tag(:foo) }
        Then { expect(gang).to_not have_tag(:bar) }
      end
    end

    describe ":criteria" do
      Given(:workers) { [b_appender, c_appender] }
      Given(:d_appender) { relay_worker { |v| v + "_d" } }
      Given(:gang) { described_class.new(workers, criteria: criteria) }
      When(:pipeline) { source | gang | d_appender }

      context "when criteria returns truthy" do
        Given(:criteria) { proc { true } }
        Then { expect(pipeline.shift).to eq("a_b_c_d") }
      end

      context "when criteria returns falsy" do
        Given(:criteria) { proc { false } }
        Then { expect(pipeline.shift).to eq("a_d") }
      end
    end
  end
end
