module Shifty
  # Shared by Worker and Gang: declares a pipeline-level policy default on
  # every node reachable upstream through the supply chain. A worker's own
  # policy declaration (its contract) always wins over the pipeline default.
  module PolicyDeclarable
    def with_policy(policy_name)
      policy_name = Policy.validate!(policy_name)
      each_upstream_node { |node| node.pipeline_policy = policy_name }
      self
    end

    # Locks the assembled topology: "the pipeline you composed is the
    # pipeline that runs" becomes a guarantee. Rewiring (supply=, Gang
    # append/roster mutation) raises FrozenError afterward. Worker
    # closure/context state stays mutable — only the topology freezes.
    #
    # Call this on the pipeline's TAIL: like with_policy, it walks the
    # supply chain upstream, so freezing a mid-chain node leaves
    # everything downstream of it mutable. And use this, not the bare
    # Object#freeze — freeze! first materializes each node's lazy task
    # and Fiber; a bare freeze skips that and the first shift would
    # raise FrozenError from deep inside the worker.
    def freeze!
      each_upstream_node { |node| node.freeze_topology_node! }
      self
    end

    private

    def each_upstream_node
      node = self
      seen = {}.compare_by_identity
      while node.respond_to?(:pipeline_policy=) && !seen[node]
        seen[node] = true
        yield node
        node = node.supply
      end
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

      # Canonicalizes and validates a policy name at declaration time, so
      # a typo fails where it was written rather than at first shift.
      def validate!(name)
        canonical(name).tap do |canonical_name|
          unless TABLE.key?(canonical_name)
            raise ArgumentError, "unknown policy #{name.inspect}"
          end
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
