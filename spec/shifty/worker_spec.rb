module Shifty
  RSpec.describe Worker do
    context "#respond_to?" do
      Then { expect(subject).to respond_to(:shift, :supply, :supply=, :"|") } # rubocop:disable Lint/SymbolConversion
    end

    describe "readiness" do
      context "with no supply" do
        context "with no task" do
          Given(:worker) { Worker.new }
          Then { expect(worker).to_not be_ready_to_work }
        end

        context "with a task which accepts a value" do
          Given(:worker) { Worker.new { |value| value.to_s } }
          Then { expect(worker).to_not be_ready_to_work }
        end

        context "with a task which doesn't accept a value" do
          Given(:worker) { Worker.new { "foo" } }
          Then { expect(worker).to be_ready_to_work }
        end
      end

      context "with a supply" do
        context "when the task accepts a value" do
          Given(:supplier) { Worker.new { "foofoo" } }
          Given(:worker) { Worker.new { |value| value.upcase } }
          Given { worker.supply = supplier }

          Then { expect(worker).to be_ready_to_work }
        end
      end
    end

    describe "can accept a task" do
      context "via the constructor" do
        context "as a block passed to ::new" do
          Given(:worker) { Worker.new { :foo } }

          Then { worker.shift == :foo }
        end

        context "as {:task => <proc/lambda>} passed to ::new" do
          Given(:callable_task) { proc { :bar } }
          Given(:worker) { Worker.new task: callable_task }

          Then { worker.shift == :bar }
        end
      end

      context "However, when a worker's task accepts an argument," do
        context "but the worker has no supply," do
          Given(:worker) { Worker.new { |value| value.do_whatnot } }

          Then { expect { subject.shift }.to raise_error(/has no supply/) }
        end
      end
    end

    describe "#suppliable?" do
      context "source worker" do
        Given(:worker) { Worker.new { :foo } }
        Then { expect(worker).to_not be_suppliable }
      end

      context "non-source worker" do
        Given(:worker) { Worker.new { |v| v + 1 } }
        Then { expect(worker).to be_suppliable }
      end
    end

    describe "#supply=" do
      context "source worker" do
        Given(:source1) { Worker.new { :foo } }
        Given(:source2) { Worker.new { :bar } }
        Then { expect { source1.supply = source2 }.to raise_error(/cannot accept a supply/) }
      end
    end

    describe "#|" do
      Given(:source_worker) { Worker.new { :foo } }
      Given(:subscribing_worker) { Worker.new { |v| "#{v}_bar".to_sym } }

      When(:pipeline) { source_worker | subscribing_worker }

      Then { subscribing_worker.supply == source_worker }
      Then { pipeline.shift == :foo_bar }
      Then { pipeline == subscribing_worker }
    end

    describe "#shift" do
      Given(:worker) { Worker.new { |v| v } }
      Given(:work_product) { :whatever }
      Given(:supply) { double shift: work_product }
      Given { worker.supply = supply }

      context "resumes a fiber" do
        Given(:fake_fiber) { double }
        Given { allow(Fiber).to receive(:new).and_return(fake_fiber) }

        When { expect(fake_fiber).to receive(:resume).once.and_return(work_product) }

        Then { worker.shift == work_product }
      end
    end

    describe "worker receives a |supply|" do
      Given(:source_worker) { Worker.new { :foo } }
      Given(:worker) { Worker.new { |value, supply| supply } }

      When(:pipeline) { source_worker | worker }

      Then { pipeline.shift == source_worker }
    end

    describe ":tags" do
      context "no  tags" do
        Given(:worker) { Worker.new }

        Then { worker.tags = [] }
      end

      context "initialization" do
        When(:worker) { Worker.new(tags: tag_arg) }

        context "a single tag" do
          Given(:tag_arg) { :foo }
          Then { worker.tags == [:foo] }
        end

        context "multiple tags" do
          Given(:tag_arg) { [:foo, :bar] }
          Then { worker.tags == [:foo, :bar] }
        end
      end

      context "by assignment" do
        Given(:worker) { Worker.new }

        When { worker.tags = tag_arg }

        context "a single tag" do
          Given(:tag_arg) { :foo }
          Then { worker.tags == [:foo] }
        end

        context "multiple tags" do
          Given(:tag_arg) { [:foo, :bar] }
          Then { worker.tags == [:foo, :bar] }
        end
      end

      describe "#has_tag?" do
        Given(:worker) { Worker.new }

        When { worker.tags = [:foo] }

        Then { expect(worker).to have_tag(:foo) }
        Then { expect(worker).to_not have_tag(:bar) }
      end
    end

    describe ":criteria" do
      Given(:source_worker) { Worker.new { :foo } }
      Given(:worker) { Worker.new(criteria: criteria) { |v| "#{v}_bar".to_sym } }

      When(:pipeline) { source_worker | worker }

      context "when criteria returns true" do
        Given(:criteria) { proc { true } }

        Then { pipeline.shift == :foo_bar }
      end

      context "when criteria returns false" do
        Given(:criteria) { proc { false } }

        Then { pipeline.shift == :foo }
      end

      context "criteria can interrogate worker" do
        Given(:criteria) { proc { |w| w.has_tag? :uno } }

        context "passing criteria" do
          Given { worker.tags = :uno }

          Then { pipeline.shift == :foo_bar }
        end

        context "failing criteria" do
          Given { worker.tags = :dos }

          Then { pipeline.shift == :foo }
        end
      end

      context "multiple criteria" do
        Given(:criteria1) { proc { |w| w.has_tag? :uno } }
        Given(:criteria2) { proc { |w| w.has_tag? :dos } }
        Given(:criteria) { [criteria1, criteria2] }

        context "passing all criteria" do
          Given { worker.tags = [:uno, :dos] }

          Then { pipeline.shift == :foo_bar }
        end

        context "passing some criteria" do
          Given { worker.tags = [:dos] }

          Then { pipeline.shift == :foo }
        end

        context "failing all criteria" do
          Given { worker.tags = [:tres] }

          Then { pipeline.shift == :foo }
        end
      end

      # TODO: worker.criteria << &proc
    end

    describe "worker receives a |context|" do
      Given(:source_worker) { Worker.new { :foo } }

      When(:pipeline) { source_worker | worker }

      context "default context" do
        Given(:worker) { Worker.new { |value, supply, context| context } }
        When(:context) { pipeline.shift }

        context "persists from one shift to the next" do
          When { context.nothing = :something }

          Then { pipeline.shift.nothing == :something }
          And  { pipeline.shift.instance_of?(OpenStruct) }
        end
      end

      context "defined context" do
        Given(:source_worker) do
          Worker.new do
            numbers = (1..3).to_a
            while (value = numbers.shift)
              Fiber.yield value
            end
          end
        end

        context "can be used for configuration" do
          Given(:context) { OpenStruct.new({foo: "bar"}) }
          Given(:worker) do
            Worker.new(context: context) do |value, supply, context|
              value && "#{context.foo}_#{value}".to_sym
            end
          end

          Then { pipeline.shift == :bar_1 }
          And  { pipeline.shift == :bar_2 }
          And  { pipeline.shift == :bar_3 }
          And  { pipeline.shift.nil? }
        end
      end
    end
  end
end
