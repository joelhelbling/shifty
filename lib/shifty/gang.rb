require 'shifty/roster'

module Shifty
  class Gang
    attr_accessor :workers

    def initialize(workers=[])
      link(workers + [])
    end

    def roster
      workers
    end

    def shift
      workers.last.shift
    end

    def ready_to_work?
      workers.first.ready_to_work?
    end

    def supply
      workers.first.supply
    end

    def supply=(source_queue)
      workers.first.supply = source_queue
    end

    def supplies(subscribing_party)
      subscribing_party.supply = self
    end
    alias_method :"|", :supplies

    private

    def link(workers)
      @workers = [workers.shift]
      while worker = workers.shift do
        Roster[self] << worker
      end
    end

  end
end
