module Shifty
  module DSL
    def source_worker(argument = nil, &block)
      ensure_correct_arity_for!(argument, block)

      series = series_from(argument)
      callable = setup_callable_for(block, series)

      return Worker.new(&callable) if series.nil?

      Worker.new(tags: [:source]) do
        series.each(&callable)

        loop do
          handoff nil
        end
      end
    end

    def relay_worker(options = {}, &block)
      options[:tags] ||= []
      options[:tags] << :relay
      ensure_regular_arity!(block)

      Worker.new(options) do |value|
        value && block.call(value)
      end
    end

    def side_worker(options = {}, &block)
      options[:tags] ||= []
      options[:tags] << :side_effect
      deprecate_mode_option!(options)
      ensure_regular_arity!(block)

      # The block must ask the worker for its policy at shift time, so the
      # local is captured by the closure before it is assigned. Not redundant.
      worker = nil
      worker = Worker.new(options) do |value| # standard:disable Style/RedundantAssignment
        value.tap do |v|
          next unless v
          # Under :isolated the block observes a private scratch copy, so
          # its mutations evaporate and the untouched value flows on.
          used_value = (worker.effective_policy == :isolated) ?
            Policy::Isolated.call(v, worker: worker) : v

          block.call(used_value)
        end
      end
      worker
    end

    def filter_worker(options = {}, &block)
      options[:tags] ||= []
      options[:tags] << :filter
      ensure_callable!(block)

      Worker.new(options) do |value, supply|
        while value && !block.call(value)
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

    def batch_worker(options = {}, &block)
      options[:tags] ||= []
      options[:tags] << :batch
      options[:gathering] ||= 1

      ensure_regular_arity!(block) if block
      batch_full = block ||
        proc { |_, batch| batch.size >= options[:gathering] }

      options[:context] = BatchContext.new({batch_full: batch_full})

      Worker.new(options) do |value, supply, context|
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

    def splitter_worker(options = {}, &block)
      options[:tags] ||= []
      options[:tags] << :splitter
      ensure_regular_arity!(block)

      Worker.new(options) do |value|
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

    # don't like that this is a second exception to accepting options..
    def trailing_worker(trail_length = 2)
      options = {tags: [:trailing]}
      trail = []
      Worker.new(options) do |value, supply|
        if value
          trail.unshift value
          if trail.size >= trail_length
            trail.pop
          end
          while trail.size < trail_length
            trail.unshift supply.shift
          end

          # Hand off a snapshot: the builder keeps mutating `trail` across
          # calls, and a downstream :frozen intake would freeze the live
          # closure array in place.
          trail.dup
        else
          value # hint: it's nil!
        end
      end
    end

    def handoff(something)
      Fiber.yield something
    end

    private

    def deprecate_mode_option!(options)
      return unless options.key?(:mode)
      mode = options.delete(:mode)
      if mode == :hardened
        warn "[shifty] side_worker mode: :hardened is deprecated and will be " \
             "removed in 1.0.0; use policy: :isolated instead."
        options[:policy] ||= :isolated
      else
        warn "[shifty] side_worker's mode: option is deprecated and ignored " \
             "(received mode: #{mode.inspect}); declare a policy: instead."
      end
    end

    def throw_with(*msg)
      raise WorkerInitializationError.new([msg].flatten.join(" "))
    end

    def ensure_callable!(callable)
      unless callable&.respond_to?(:call)
        throw_with "You must supply a callable"
      end
    end

    def ensure_regular_arity!(block)
      if block.arity != 1
        throw_with \
          "Worker must accept exactly one argument (arity == 1)"
      end
    end

    # only valid for #source_worker
    def ensure_correct_arity_for!(argument, block)
      return unless block
      if argument
        ensure_regular_arity!(block)
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
