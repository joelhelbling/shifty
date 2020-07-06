module Shifty
  class WorkerInitializationError < StandardError; end

  module DSL
    def source_worker(argument = nil, &block)
      ensure_correct_arity_for!(argument, block)

      series = series_from(argument)
      callable = setup_callable_for(block, series)

      return Worker.new(&callable) if series.nil?

      Worker.new do
        series.each(&callable)

        loop do
          handoff nil
        end
      end
    end

    def relay_worker(&block)
      ensure_regular_arity(block)

      Worker.new do |value|
        value && block.call(value)
      end
    end

    def side_worker(mode = :normal, &block)
      ensure_regular_arity(block)

      Worker.new(tags: [:side_effect]) do |value|
        value.tap do |v|
          used_value = mode == :hardened ?
            Marshal.load(Marshal.dump(v)) : v

          v && block.call(used_value)
        end
      end
    end

    def filter_worker(argument = nil, &block)
      if block && argument.respond_to?(:call)
        throw_with "You cannot supply two callables"
      end
      callable = argument.respond_to?(:call) ? argument : block
      ensure_callable(callable)

      Worker.new do |value, supply|
        while value && !callable.call(value)
          value = supply.shift
        end
        value
      end
    end

    class BatchContext < OpenStruct
      def batch_complete?(value, collection)
        value.nil? ||
          !!batch_full.call(value, collection)
      end
    end

    def batch_worker(options = {gathering: 1}, &block)
      ensure_regular_arity(block) if block
      batch_full = block ||
        proc { |_, batch| batch.size >= options[:gathering] }

      batch_context = BatchContext.new({batch_full: batch_full})

      Worker.new(context: batch_context) do |value, supply, context|
        if value
          context.collection = [value]
          until context.batch_complete?(
            context.collection.last,
            context.collection
          )
            context.collection << supply.shift
          end
          context.collection.compact
        end
      end
    end

    def splitter_worker(&block)
      ensure_regular_arity(block)

      Worker.new do |value|
        if value.nil?
          value
        else
          parts = [block.call(value)].flatten
          while parts.size > 1
            handoff parts.shift
          end
          parts.shift
        end
      end
    end

    def trailing_worker(trail_length = 2)
      trail = []
      Worker.new do |value, supply|
        if value
          trail.unshift value
          if trail.size >= trail_length
            trail.pop
          end
          while trail.size < trail_length
            trail.unshift supply.shift
          end

          trail
        else
          value
        end
      end
    end

    def handoff(something)
      Fiber.yield something
    end

    private

    def throw_with(*msg)
      raise WorkerInitializationError.new([msg].flatten.join(" "))
    end

    def ensure_callable(callable)
      unless callable&.respond_to?(:call)
        throw_with "You must supply a callable"
      end
    end

    def ensure_regular_arity(block)
      if block.arity != 1
        throw_with \
          "Worker must accept exactly one argument (arity == 1)"
      end
    end

    # only valid for #source_worker
    def ensure_correct_arity_for!(argument, block)
      return unless block
      if argument
        ensure_regular_arity(block)
      elsif block.arity > 0
        throw_with \
          "Source worker cannot accept any arguments (arity == 0)"
      end
    end

    def series_from(series)
      return if series.nil?
      if series.respond_to?(:to_a)
        series.to_a
      elsif series.respond_to?(:scan)
        series.scan(/./)
      else
        [series]
      end
    end

    def setup_callable_for(block, series)
      return block unless series
      if block
        proc { |value| handoff block.call(value) }
      else
        proc { |value| handoff value }
      end
    end
  end
end
