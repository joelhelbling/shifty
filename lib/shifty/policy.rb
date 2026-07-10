module Shifty
  # Shared by Worker and Gang: declares a pipeline-level policy default on
  # every node reachable upstream through the supply chain. A worker's own
  # policy declaration (its contract) always wins over the pipeline default.
  module PolicyDeclarable
    def with_policy(policy_name)
      policy_name = Policy.canonical(policy_name)
      Policy.resolve(policy_name)
      node = self
      while node.respond_to?(:pipeline_policy=)
        node.pipeline_policy = policy_name
        node = node.supply
      end
      self
    end
  end

  # Handoff policies govern how a value crosses a worker boundary.
  # Each policy responds to #call(value, worker:) and returns the value
  # the worker's task will receive.
  module Policy
    # Deeply freezes the value in place (zero copies) so any mutation,
    # anywhere in the pipeline, raises at the worker that attempted it.
    # IO-like values are rejected proactively: Ractor.make_shareable would
    # otherwise freeze a live handle in place — a process-wide side effect
    # on shared resources like loggers or $stdout.
    Frozen = lambda do |value, worker:|
      if value.is_a?(IO)
        raise UnshareableValue.new(worker: worker, policy: :frozen, value: value)
      end
      begin
        Ractor.make_shareable(value)
      rescue Ractor::Error => e
        raise UnshareableValue.new(worker: worker, policy: :frozen, value: value, cause: e)
      end
    end

    # Hands the task a private, mutable deep copy. Marshal is the mechanism
    # because Ractor.make_shareable(copy: true) returns a *frozen* copy,
    # which cannot satisfy the :isolated contract of a mutable scratch value.
    Isolated = lambda do |value, worker:|
      Marshal.load(Marshal.dump(value))
    rescue TypeError => e
      raise UnshareableValue.new(worker: worker, policy: :isolated, value: value, cause: e)
    end

    # The escape hatch: the raw reference passes through untouched.
    Shared = ->(value, worker:) { value }

    TABLE = {
      frozen: Frozen,
      isolated: Isolated,
      shared: Shared
    }.freeze

    ALIASES = {hardened: :isolated}.freeze

    class << self
      def resolve(name)
        TABLE.fetch(canonical(name)) do
          raise ArgumentError, "unknown policy #{name.inspect}"
        end
      end

      def canonical(name)
        if ALIASES.key?(name)
          replacement = ALIASES[name]
          warn "[shifty] policy :#{name} is deprecated and will be " \
               "removed in 1.0.0; use :#{replacement} instead."
          replacement
        else
          name
        end
      end
    end

    # Wraps a worker's supply so that values the task pulls directly
    # (e.g. filter/batch/trailing workers calling supply.shift mid-task)
    # cross the boundary under the same policy as the primary intake.
    class Supply
      def initialize(supply, worker)
        @supply = supply
        @worker = worker
      end

      def shift
        @worker.intake(@supply.shift)
      end
    end
  end
end
