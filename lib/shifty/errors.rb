module Shifty
  class Error < StandardError; end

  class WorkerError < Error; end

  class WorkerInitializationError < Error; end

  class PolicyError < Error
    attr_reader :worker, :policy, :value

    def cause
      @wrapped_cause || super
    end

    private

    def worker_label
      label = (worker.respond_to?(:name) && worker.name) ? "`#{worker.name}`" : "(unnamed)"
      tags = worker.respond_to?(:tags) ? worker.tags : []
      tags&.any? ? "#{label} (tags: #{tags.inspect})" : label
    end
  end

  # Raised when a task mutates a value it received under a policy that
  # forbids mutation. Wraps the original FrozenError (never masks it) and
  # names the worker, the effective policy, and the object the task tried
  # to mutate, with a heuristic locating that object relative to the
  # handed-off value.
  class PolicyViolation < PolicyError
    attr_reader :receiver

    def initialize(worker:, policy:, receiver:, value:, cause:)
      @worker = worker
      @policy = policy
      @receiver = receiver
      @value = value
      @wrapped_cause = cause
      super(build_message)
    end

    private

    def build_message
      <<~MSG
        Worker #{worker_label} received its value under the #{policy.inspect} handoff \
        policy, and its task attempted to mutate #{receiver_description}.

        Either make the task non-destructive — e.g. `map` instead of `map!`, \
        `value.with(...)`, `arr + [x]`, `hash.merge(...)` — or declare a different \
        policy on this worker: `policy: :isolated` (task works on a private scratch \
        copy) or `policy: :shared` (raw reference; no protection).
      MSG
    end

    def receiver_description
      if receiver.equal?(value)
        "an instance of #{receiver.class} — the handed-off value itself"
      elsif reachable_from_value?
        "an instance of #{receiver.class} reachable from the handed-off value"
      else
        "an instance of #{receiver.class} (#{receiver.inspect[0, 80]}), which may be " \
          "unrelated to the handed-off value (an instance of #{value.class}); " \
          "inspect both to judge"
      end
    end

    # Bounds the diagnostic graph walk; past this the heuristic gives up
    # and reports the honest "inspect both to judge" fallback rather than
    # risking a SystemStackError that would mask the violation itself.
    MAX_REACHABILITY_NODES = 50_000

    def reachable_from_value?
      seen = {}.compare_by_identity
      stack = [value]
      until stack.empty?
        node = stack.pop
        next if node.nil? || seen[node]
        return false if seen.size >= MAX_REACHABILITY_NODES
        seen[node] = true
        return true if node.equal?(receiver)
        stack.concat(children_of(node))
      end
      false
    end

    def children_of(node)
      case node
      when Array then node
      when Hash then node.keys + node.values
      when Struct then node.to_a
      else
        members = (node.respond_to?(:to_h) && node.is_a?(Data)) ? node.to_h.values : []
        members + node.instance_variables.map { |iv| node.instance_variable_get(iv) }
      end
    end
  end

  # Raised at the handoff itself when a value cannot cross the boundary
  # under the effective policy (cannot be frozen or deep-copied).
  class UnshareableValue < PolicyError
    def initialize(worker:, policy:, value:, cause: nil)
      @worker = worker
      @policy = policy
      @value = value
      @wrapped_cause = cause
      super(build_message)
    end

    private

    def build_message
      "Worker #{worker_label} received a value (an instance of #{value.class}) " \
        "that cannot cross the handoff boundary under the #{policy.inspect} policy: " \
        "it cannot be #{(policy == :isolated) ? "deep-copied" : "frozen"}. " \
        "Declare `policy: :shared` on this worker (raw pass-by-reference), " \
        "or restructure the value."
    end
  end
end
