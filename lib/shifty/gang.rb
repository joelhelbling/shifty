require "shifty/roster"

module Shifty
  class Gang
    attr_accessor :roster

    def initialize(workers = [])
      @roster = Roster.new(workers)
    end

    def shift
      roster.last.shift
    end

    def ready_to_work?
      roster.first.ready_to_work?
    end

    def supply
      roster.first.supply
    end

    def supply=(source_queue)
      roster.first.supply = source_queue
    end

    def supplies(subscribing_worker)
      subscribing_worker.supply = self
    end
    alias | supplies

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
