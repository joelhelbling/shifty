require "forwardable"

module Shifty
  class Roster
    extend Forwardable

    attr_reader :workers

    def initialize(workers = [])
      @workers = []
      workers.each do |worker|
        push worker
      end
    end

    def_delegators :workers, :first, :last

    def push(worker)
      if worker
        worker.supplier = workers.last unless workers.empty?
        workers << worker
      end
    end
    alias_method :<<, :push

    def pop
      workers.pop.tap do |popped|
        popped.supplier = nil
      end
    end

    def shift
      workers.shift.tap do
        workers.first.supplier = nil
      end
    end

    def unshift(worker)
      workers.first.supplier = worker
      workers.unshift worker
    end
  end
end
