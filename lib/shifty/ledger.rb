module Shifty
  class Ledger
    class << self
      def [](first)
        new(first)
      end
    end

    def initialize(first)
      @collection = [first]
    end

    def last
      @collection.last
    end

    def push(value)
      @collection.push(value)
      self
    end

    def pop
      @collection.pop
      self
    end
  end
end
