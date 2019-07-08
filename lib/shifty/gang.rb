require "shifty/roster"
require "shifty/taggable"

module Shifty
  class Gang
    attr_reader :roster, :tags

    include Taggable

    def initialize(workers = [], p = {})
      @roster = Roster.new(workers)
      self.criteria = p[:criteria]
      self.tags     = p[:tags]
    end

    def shift
      if criteria_passes?
        roster.last.shift
      else
        roster.first.supply.shift
      end
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
