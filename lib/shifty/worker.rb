require "ostruct"

module Shifty
  class Worker
    attr_reader :supply, :tags

    def initialize(p = {}, &block)
      @supply   = p[:supply]
      @task     = block || p[:task]
      @context  = p[:context] || OpenStruct.new
      @criteria = [p[:criteria] || []].flatten
      self.tags = p[:tags] || []
    end

    def shift
      ensure_ready_to_work!
      workflow.resume
    end

    def ready_to_work?
      @task && (supply || !task_accepts_a_value?)
    end

    def supplies(subscribing_party)
      subscribing_party.supply = self
      subscribing_party
    end
    alias | supplies

    def supply=(supplier)
      raise WorkerError.new("Worker is a source, and cannot accept a supply") unless suppliable?
      @supply = supplier
    end

    def suppliable?
      @task && @task.arity > 0
    end

    def tags=(tag_arg)
      @tags = [tag_arg].flatten
    end

    def has_tag?(tag)
      tags.include? tag
    end

    private

    def ensure_ready_to_work!
      @task ||= default_task

      unless ready_to_work?
        raise "This worker's task expects to receive a value from a supplier, but has no supply."
      end
    end

    def workflow
      @my_little_machine ||= Fiber.new {
        loop do
          value = supply&.shift
          if criteria_passes?
            Fiber.yield @task.call(value, supply, @context)
          else
            Fiber.yield value
          end
        end
      }
    end

    def default_task
      proc { |value| value }
    end

    def task_accepts_a_value?
      @task.arity > 0
    end

    def task_method_exists?
      methods.include? :task
    end

    def task_method_accepts_a_value?
      method(:task).arity > 0
    end

    def criteria_passes?
      return true if @criteria.empty?

      @criteria.all? { |c| c.call(self) }
    end
  end

  class WorkerError < StandardError; end
end
