require "spec_helper"

module Shifty
  Token = Data.define(:payload)

  RSpec.describe "handoff policy declaration and precedence" do
    include DSL

    after { Shifty.reset_configuration! }

    describe "worker-level declaration" do
      context "a worker declaring its own policy uses it" do
        Given(:worker) { Worker.new(policy: :isolated) { |v| v } }
        Then { expect(worker.effective_policy).to eq(:isolated) }
      end

      context "an undeclared worker falls back to the global default" do
        Given(:worker) { Worker.new { |v| v } }
        Then { expect(worker.effective_policy).to eq(:frozen) }
      end

      context "the global default is configurable" do
        Given { Shifty.configure { |c| c.default_policy = :shared } }
        Given(:worker) { Worker.new { |v| v } }
        Then { expect(worker.effective_policy).to eq(:shared) }
      end
    end

    describe "pipeline-level declaration via #with_policy" do
      Given(:source) { Worker.new { |v| v } }
      Given(:middle) { Worker.new { |v| v } }
      Given(:declared) { Worker.new(policy: :shared) { |v| v } }

      context "sets the pipeline default on every upstream worker" do
        Given(:pipeline) { (source | middle).with_policy(:isolated) }
        Then { expect(pipeline).to be middle }
        And { expect(middle.effective_policy).to eq(:isolated) }
        And { expect(source.effective_policy).to eq(:isolated) }
      end

      context "does not override a worker's own declaration" do
        When { (source | declared).with_policy(:isolated) }
        Then { expect(declared.effective_policy).to eq(:shared) }
        And { expect(source.effective_policy).to eq(:isolated) }
      end

      context "rejects an unknown policy eagerly" do
        Then do
          expect { source.with_policy(:bogus) }
            .to raise_error(ArgumentError, /unknown policy/)
        end
      end
    end

    describe "enforcement under :frozen (the default)" do
      context "a task mutating its handed-off value raises PolicyViolation" do
        Given(:source) { Worker.new { [:foo] } }
        Given(:mutator) { Worker.new(name: "enricher", tags: [:etl]) { |v| v << :bar } }
        Given(:pipeline) { source | mutator }

        When(:violation) do
          pipeline.shift
          nil
        rescue PolicyViolation => e
          e
        end

        Then { expect(violation).to be_a(PolicyViolation) }
        And { expect(violation.worker).to be mutator }
        And { expect(violation.policy).to eq(:frozen) }
        And { expect(violation.receiver).to eq([:foo]) }
        And { expect(violation.value).to eq([:foo]) }
        And { expect(violation.cause).to be_a(FrozenError) }
        And { expect(violation.message).to match(/enricher/) }
        And { expect(violation.message).to match(/:frozen/) }
        And { expect(violation.message).to match(/Array/) }
        And { expect(violation.message).to match(/the handed-off value itself/) }
        And { expect(violation.message).to match(/:isolated|:shared/) }
      end
    end

    describe "enforcement under :isolated" do
      context "the task mutates a private copy; upstream is protected, mutation flows on" do
        Given(:original) { [:foo] }
        Given(:source) do
          value = original
          Worker.new { value }
        end
        Given(:appender) { Worker.new(policy: :isolated) { |v| v << :bar } }
        Given(:pipeline) { source | appender }

        When(:result) { pipeline.shift }

        Then { expect(result).to eq([:foo, :bar]) }
        And { expect(original).to eq([:foo]) }
        And { expect(result).not_to be original }
      end
    end

    describe "the remaining policy × value-shape cells" do
      context ":frozen × Data — copy-on-write via #with is the blessed idiom" do
        Given(:token_class) { Token }
        Given(:source) { Worker.new { Token.new(payload: "raw") } }
        Given(:enricher) { Worker.new { |v| v.with(payload: v.payload.upcase) } }
        When(:result) { (source | enricher).shift }

        Then { expect(result.payload).to eq("RAW") }
        And { expect(result).to be_frozen }
      end

      context ":frozen × nil — the end-of-stream sentinel passes through" do
        Given(:source) { source_worker [:only] }
        Given(:relay) { relay_worker { |v| v } }
        Given(:pipeline) { source | relay }
        When { pipeline.shift }
        Then { expect(pipeline.shift).to be_nil }
      end

      context ":isolated × Data with a mutable member — the copy's member is private" do
        Given(:member) { [1] }
        Given(:source) do
          value = member
          Worker.new { Token.new(payload: value) }
        end
        Given(:appender) do
          Worker.new(policy: :isolated) do |v|
            v.payload << 2
            v
          end
        end
        When(:result) { (source | appender).shift }

        Then { expect(result.payload).to eq([1, 2]) }
        And { expect(member).to eq([1]) }
      end

      context ":shared × Array — mutation leaks to holders of the same reference" do
        Given(:original) { [:foo] }
        Given(:source) do
          value = original
          Worker.new { value }
        end
        Given(:appender) { Worker.new(policy: :shared) { |v| v << :bar } }
        When(:result) { (source | appender).shift }

        Then { expect(result).to be original }
        And { expect(original).to eq([:foo, :bar]) }
      end

      context ":shared × IO — an unfreezable value passes through untouched" do
        Given(:io) { File.open(File::NULL, "w") }
        Given(:source) do
          value = io
          Worker.new { value }
        end
        Given(:logger) { Worker.new(policy: :shared) { |v| v } }
        When(:result) { (source | logger).shift }

        Then { expect(result).to be io }
        And { expect(io).not_to be_frozen }
      end
    end

    describe "unshareable values" do
      context ":frozen × IO raises UnshareableValue without freezing the live handle" do
        Given(:io) { File.open(File::NULL, "w") }
        Given(:source) do
          value = io
          Worker.new { value }
        end
        Given(:consumer) { Worker.new(name: "sink") { |v| v } }
        Given(:pipeline) { source | consumer }

        When(:error) do
          pipeline.shift
          nil
        rescue UnshareableValue => e
          e
        end

        Then { expect(error).to be_a(UnshareableValue) }
        And { expect(error.policy).to eq(:frozen) }
        And { expect(error.value).to be io }
        And { expect(error.message).to match(/:shared/) }
        And { expect(io).not_to be_frozen }
        And { expect { io.write("still usable") }.not_to raise_error }
      end

      context ":frozen × Proc raises UnshareableValue wrapping the Ractor error" do
        Given(:source) { Worker.new { proc { 1 } } }
        Given(:consumer) { Worker.new { |v| v } }

        When(:error) do
          (source | consumer).shift
          nil
        rescue UnshareableValue => e
          e
        end

        Then { expect(error).to be_a(UnshareableValue) }
        And { expect(error.cause).to be_a(Ractor::Error) }
      end

      context ":isolated failure set (the Marshal set)" do
        Given(:consumer_policy) { :isolated }

        [
          ["a File", -> { File.open(File::NULL, "w") }],
          ["a Proc", -> { proc { 1 } }],
          ["a lazy enumerator", -> { [1, 2].each.lazy }],
          ["a StringIO", -> { StringIO.new }],
          ["an object with a singleton method", -> {
            Object.new.tap { |o|
              def o.x
              end
            }
          }]
        ].each do |label, build|
          context "rejects #{label}" do
            Given(:source) { Worker.new { build.call } }
            Given(:consumer) { Worker.new(policy: :isolated) { |v| v } }
            Then do
              expect { (source | consumer).shift }
                .to raise_error(UnshareableValue, /cannot be deep-copied/)
            end
          end
        end
      end
    end

    describe "boundary cases" do
      context "values pulled mid-task via supply.shift are governed (filter_worker)" do
        Given(:source) { source_worker [[1], [2], [3]] }
        Given(:filter) { filter_worker { |v| v << :seen } }
        Given(:pipeline) { source | filter }

        Then { expect { pipeline.shift }.to raise_error(PolicyViolation) }
      end

      context "every part a splitter yields arrives frozen downstream" do
        Given(:source) { source_worker ["a-b-c"] }
        Given(:splitter) { splitter_worker { |v| v.split("-") } }
        Given(:consumer) { relay_worker { |v| v } }
        Given(:pipeline) { source | splitter | consumer }

        When(:parts) { 3.times.map { pipeline.shift } }

        Then { expect(parts).to eq(%w[a b c]) }
        And { expect(parts).to all(be_frozen) }
      end

      context "trailing_worker under the :frozen default keeps working mid-pipeline" do
        Given(:source) { source_worker (1..4).to_a }
        Given(:trailing) { trailing_worker 2 }
        Given(:consumer) { relay_worker { |v| v } }
        Given(:pipeline) { source | trailing | consumer }

        When(:results) { 3.times.map { pipeline.shift } }

        Then { expect(results).to eq([[2, 1], [3, 2], [4, 3]]) }
        And { expect(results.first).to eq([2, 1]) }
      end

      context "side_worker(policy: :isolated) — mutations evaporate" do
        Given(:source) { source_worker [[:foo], [:bar]] }
        Given(:worker) { side_worker(policy: :isolated) { |v| v << :boo } }
        When { source | worker }

        Then { worker.shift == [:foo] }
        And { worker.shift == [:bar] }
        And { worker.shift.nil? }
      end

      context "a criteria-bypassed value is still policy-governed" do
        Given(:source) { Worker.new { [:foo] } }
        Given(:skipper) do
          Worker.new(criteria: ->(w) { false }) { |v| v }
        end
        When(:result) { (source | skipper).shift }

        Then { expect(result).to eq([:foo]) }
        And { expect(result).to be_frozen }
      end
    end

    describe "the :hardened deprecation shim" do
      Given(:source) { source_worker [[:foo], [:bar]] }
      Given(:unsafe_task) { proc { |v| v << :boo } }

      context "side_worker mode: :hardened behaves as :isolated and warns" do
        Given(:warning) do
          capture_stderr do
            @worker = side_worker(mode: :hardened, &unsafe_task)
          end
        end
        Given(:pipeline) { source | @worker }

        Then { expect(warning).to match(/:hardened is deprecated/) }
        And { expect(pipeline.shift).to eq([:foo]) }
        And { expect(pipeline.shift).to eq([:bar]) }
      end

      context "Worker policy: :hardened maps to :isolated and warns" do
        Given(:warning) do
          capture_stderr do
            @worker = Worker.new(policy: :hardened) { |v| v }
          end
        end

        Then { expect(warning).to match(/:hardened is deprecated/) }
        And { expect(@worker.effective_policy).to eq(:isolated) }
      end
    end

    describe "PolicyViolation receiver heuristic" do
      Given(:catch_violation) do
        lambda do |pipeline|
          pipeline.shift
          nil
        rescue PolicyViolation => e
          e
        end
      end

      context "mutating an object nested inside the handed-off value" do
        Given(:source) { Worker.new { {items: [1, 2]} } }
        Given(:mutator) { Worker.new { |v| v[:items] << 3 } }
        When(:violation) { catch_violation.call(source | mutator) }

        Then { expect(violation.receiver).to eq([1, 2]) }
        And { expect(violation.receiver).not_to eq(violation.value) }
        And { expect(violation.message).to match(/reachable from the handed-off value/) }
      end

      context "an unrelated FrozenError from the task's own code is not misattributed" do
        Given(:own_frozen_thing) { [:mine].freeze }
        Given(:source) { Worker.new { [:foo] } }
        Given(:mutator) do
          thing = own_frozen_thing
          Worker.new { |v| thing << :other }
        end
        When(:violation) { catch_violation.call(source | mutator) }

        Then { expect(violation.receiver).to eq([:mine]) }
        And { expect(violation.value).to eq([:foo]) }
        And { expect(violation.message).to match(/may be unrelated to the handed-off value/) }
      end
    end

    describe "Gang-level declaration" do
      Given(:a) { Worker.new { |v| v } }
      Given(:b) { Worker.new { |v| v } }

      context "policy: kwarg fans out to the roster as pipeline default" do
        Given!(:gang) { Gang.new([a, b], policy: :isolated) }
        Then { expect(a.effective_policy).to eq(:isolated) }
        And { expect(b.effective_policy).to eq(:isolated) }
      end

      context "#with_policy fans out and is chainable" do
        Given(:gang) { Gang[a, b] }
        When(:result) { gang.with_policy(:shared) }
        Then { expect(result).to be gang }
        And { expect(a.effective_policy).to eq(:shared) }
        And { expect(b.effective_policy).to eq(:shared) }
      end

      context "#with_policy on a chain ending in a worker walks past a gang to upstream workers" do
        Given(:upstream) { Worker.new { |v| v } }
        Given(:gang) { Gang[a, b] }
        Given(:tail) { Worker.new { |v| v } }
        When { (upstream | gang | tail).with_policy(:isolated) }
        Then { expect(tail.effective_policy).to eq(:isolated) }
        And { expect(a.effective_policy).to eq(:isolated) }
        And { expect(b.effective_policy).to eq(:isolated) }
        And { expect(upstream.effective_policy).to eq(:isolated) }
      end
    end
  end
end
