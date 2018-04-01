module Shifty
  RSpec.describe Worker do
    it { should respond_to(:shift, :supply, :supply=, :"|") }

    describe "readiness" do
      context "with no supply" do
        context "with no task" do
          it { should_not be_ready_to_work }
        end
        context "with a task which accepts a value" do
          subject do
            Worker.new { |value| value.to_s }
          end
          it { should_not be_ready_to_work }
        end
        context "with a task which doesn't accept a value" do
          subject do
            Worker.new { "foo" }
          end
          it { should be_ready_to_work }
        end
      end

      context "with a supply" do
        context "with no task" do
          subject { Worker.new }
          it { should_not be_ready_to_work }
        end
        context "with a task which accepts a value" do
          before do
            subject.supply = Worker.new { "foofoo" }
          end
          subject do
            Worker.new { |value| value.upcase }
          end
          it { should be_ready_to_work }
        end
        context "with a task which doesn't accept a value" do
          subject do
            Worker.new { "bar" }
          end
          it { should be_ready_to_work }
        end
      end
    end

    describe "can accept a task" do
      Given(:result) { double :copasetic? => true }

      context "via the constructor" do

        context "as a block passed to ::new" do
          Given(:subject) do
            Worker.new do
              result
            end
          end

          Then { expect(subject.shift).to be_copasetic }
        end

        context "as {:task => <proc/lambda>} passed to ::new" do
          Given(:callable_task) { Proc.new { result } }

          Given(:subject) do
            Worker.new task: callable_task
          end

          Then { expect(subject.shift).to be_copasetic }
        end
      end

      context "However, when a worker's task accepts an argument," do
        context "but the worker has no supply," do
          subject { Worker.new { |value| value.do_whatnot } }
          specify "#shift throws an exception" do
            expect { subject.shift }.to raise_error(/has no supply/)
          end
        end
      end

    end

    describe '#suppliable?' do
      context 'source worker' do
        Given(:worker) { Worker.new { :foo } }
        Then { expect(worker).to_not be_suppliable }
      end
      context 'non-source worker' do
        Given(:worker) { Worker.new { |v| v +=1 } }
        Then { expect(worker).to be_suppliable }
      end
    end

    describe '#supply=' do
      context 'source worker' do
        Given(:source1) { Worker.new { :foo } }
        Given(:source2) { Worker.new { :bar } }
        Then { expect { source1.supply = source2 }.to raise_error(/cannot accept a supply/) }
      end
    end

    describe "= EXAMPLE WORKER TYPES =" do

      let(:source_worker) do
        Worker.new do
          numbers = (1..3).to_a
          while value = numbers.shift
            Fiber.yield value
          end
        end
      end

      let(:relay_worker) do
        Worker.new do |number|
          number && number * 3
        end
      end

      describe "The Source Worker" do
        Given(:the_self_starter) { source_worker }

        context "generates values without a supply." do
          Then { the_self_starter.shift == 1 }
          And  { the_self_starter.shift == 2 }
          And  { the_self_starter.shift == 3 }
          And  { the_self_starter.shift.nil? }
        end
      end

      describe "The Relay Worker" do
        Given { relay_worker.supply = source_worker }

        Given(:triplizer) { relay_worker }

        context "operates on values received from its supply." do
          Then { triplizer.shift == 3 }
          And  { triplizer.shift == 6 }
          And  { triplizer.shift == 9 }
          And  { triplizer.shift.nil? }
        end
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

    describe 'worker receives a |supply|' do
      Given(:source_worker) { Worker.new { :foo } }
      Given(:worker) { Worker.new { |value, supply| supply } }

      When(:pipeline) { source_worker | worker }

      Then { pipeline.shift == source_worker }
    end

    describe 'worker receives a |context|' do
      Given(:source_worker) { Worker.new { :foo } }

      When(:pipeline) { source_worker | worker }

      context 'default context' do
        Given(:worker) { Worker.new { |value, supply, context| context } }
        When(:context) { pipeline.shift }

        context 'persists from one shift to the next' do
          When { context.nothing = :something }

          Then { pipeline.shift.nothing == :something }
          And  { pipeline.shift.class == OpenStruct }
        end
      end

      context 'defined context' do
        Given(:source_worker) do
          Worker.new do
            numbers = (1..3).to_a
            while value = numbers.shift
              Fiber.yield value
            end
          end
        end

        context 'can be used for configuration' do
          Given(:context) { OpenStruct.new({ foo: 'bar' }) }
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
