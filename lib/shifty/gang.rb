require "shifty/roster"
require "shifty/taggable"

module Shifty
  class Gang
    attr_reader :roster, :tags

    include Taggable
    include PolicyDeclarable

    def initialize(workers = [], p = {})
      @roster = Roster.new(workers)
      self.criteria = p[:criteria]
      self.tags     = p[:tags]
      self.pipeline_policy = Policy.validate!(p[:policy]) if p[:policy]
    end

    def pipeline_policy=(policy_name)
      # Persisted so workers appended after the declaration inherit it.
      @pipeline_policy = policy_name
      roster.workers.each { |w| w.pipeline_policy = policy_name }
    end

    attr_reader :pipeline_policy

    def shift
      if criteria_passes?
        roster.last.shift
      else
        # Even when the gang's criteria bypasses its workers, the value
        # still crosses the gang's boundary — govern it with the entry
        # worker's policy, matching Worker#shift's bypass behavior.
        roster.first.intake(roster.first.supply.shift)
      end
    end

    def ready_to_work?
      roster.first.ready_to_work?
    end

    def supply
      roster.first&.supply
    end

    def supply=(supplier)
      roster.first.supply = supplier
    end

    def supplies(subscribing_worker)
      subscribing_worker.supply = self
      subscribing_worker
    end
    alias_method :|, :supplies

    def append(worker)
      roster << worker
      worker.pipeline_policy = pipeline_policy if pipeline_policy
    end

    # Freezes every roster member plus the roster's own membership, so
    # append/push/pop/shift/unshift all raise FrozenError afterward.
    def freeze_topology_node!
      roster.workers.each(&:freeze_topology_node!)
      roster.workers.freeze
      roster.freeze
      freeze
    end

    class << self
      def [](*workers)
        new workers
      end
    end
  end
end
