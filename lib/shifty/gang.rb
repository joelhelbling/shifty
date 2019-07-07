require "shifty/roster"

module Shifty
  class Gang
    attr_reader :roster, :tags

    def initialize(workers = [], p = {})
      @roster = Roster.new(workers)
      @criteria = [p[:criteria] || []].flatten
      self.tags = p[:tags] || []
    end

    def tags=(tag_arg)
      @tags = [tag_arg].flatten
    end

    def has_tag?(tag)
      tags.include? tag
    end

    def shift
      if criteria_passes?
        roster.last.shift
      else
        roster.first.supply.shift
      end
    end

    def criteria_passes?
      return true if @criteria.empty?

      @criteria.all? { |c| c.call(self) }
    end

    def ready_to_work?
      roster.first.ready_to_work?
    end

    def supply
      roster.first.supply
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
    end

    class << self
      def [](*workers)
        new workers
      end
    end
  end
end
