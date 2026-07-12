require "shifty"

module Shifty
  # Test harness: runs a worker through the framework so unit tests
  # exercise the same handoff policy the production pipeline will.
  # Deliberately not loaded by `require "shifty"` — opt in with
  # `require "shifty/testing"`.
  module Testing
    class << self
      # Feeds the inputs to the worker via a source and collects its
      # outputs until the end-of-stream sentinel (nil). The worker's
      # declared/effective policy governs each handoff, exactly as in
      # production; pass policy: to override it for policy-matrix tests.
      def run(worker, inputs:, policy: nil, max_shifts: 10_000)
        harness(worker, policy) do |subject|
          subject.supplier = source_for(inputs)
          outputs = []
          shifts = 0
          until (value = subject.shift).nil?
            outputs << value
            if (shifts += 1) > max_shifts
              raise Error, "Shifty::Testing.run exceeded #{max_shifts} shifts " \
                "without seeing the nil end-of-stream sentinel. The worker's " \
                "task probably converts nil into a non-nil value; let nil " \
                "pass through (e.g. `value && ...`), or raise max_shifts:."
            end
          end
          outputs
        end
      end

      # The mutation detector (§6.4): hands the task a private mutable
      # deep copy and reports whether the task changed it — surfacing
      # mutation even when the current policy permits or hides it.
      def mutates_input?(worker, input)
        copy = begin
          Marshal.load(Marshal.dump(input))
        rescue TypeError => e
          raise Error, "Shifty::Testing.mutates_input? needs a deep-copyable " \
            "(Marshal-dumpable) input, but got an instance of #{input.class} " \
            "(#{e.message})."
        end
        baseline = Marshal.dump(copy)
        harness(worker, :shared) do |subject|
          subject.supplier = source_for([copy])
          subject.shift
        end
        Marshal.dump(copy) != baseline
      end

      private

      # Temporarily rewires the caller's actual worker (a dup would defeat
      # task closures that reference their own worker, e.g. side_worker's
      # policy check) and restores its policy, supplier, and Fiber afterward,
      # so the harness never leaves a mark on the worker under test.
      def harness(worker, policy)
        saved = {
          policy: worker.instance_variable_get(:@policy),
          supplier: worker.instance_variable_get(:@supplier),
          fiber: worker.instance_variable_get(:@my_little_machine)
        }
        worker.instance_variable_set(:@policy, Policy.validate!(policy)) if policy
        worker.instance_variable_set(:@my_little_machine, nil)
        worker.instance_variable_set(:@supplier, nil)
        yield worker
      ensure
        worker.instance_variable_set(:@policy, saved[:policy])
        worker.instance_variable_set(:@supplier, saved[:supplier])
        worker.instance_variable_set(:@my_little_machine, saved[:fiber])
      end

      def source_for(inputs)
        series = inputs.dup
        Worker.new(tags: [:source]) do
          series.each { |input| Fiber.yield input }
          loop { Fiber.yield nil }
        end
      end
    end
  end
end
