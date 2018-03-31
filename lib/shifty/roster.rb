module Shifty
  module Roster
    class << self
      def [](gang)
        RosterizedGang.new(gang)
      end
    end
  end

  class RosterizedGang
    attr_reader :gang

    def initialize(gang)
      @gang = gang
    end

    def workers
      gang.workers
    end

    def push(worker)
      if worker
        worker.supply = workers.last
        workers << worker
      end
    end
    alias_method :"<<", :push

    def pop
      gang.workers.pop.tap do |popped|
        popped.supply = nil
      end
    end

    def shift
      workers.shift.tap do
        workers.first.supply = nil
      end
    end

    def unshift(worker)
      workers.first.supply = worker
      workers.unshift worker
    end
  end
end
