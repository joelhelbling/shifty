require 'ostruct'

module Shifty
  class Worker
    attr_reader :supply

    def initialize(p={}, &block)
      @supply   = p[:supply]
      @task     = block || p[:task]
      @context  = p[:context] || OpenStruct.new
      # don't define default task here
      # because we want to allow for
      # an initialized worker to have
      # a task injected, including
      # method-based tasks.
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
    alias_method :"|", :supplies

    def supply=(supplier)
      raise WorkerError.new("Worker is a source, and cannot accept a supply") unless suppliable?
      @supply = supplier
    end

    def suppliable?
      @task && @task.arity > 0
    end

    private

    def ensure_ready_to_work!
      @task ||= default_task

      unless ready_to_work?
        raise "This worker's task expects to receive a value from a supplier, but has no supply."
      end
    end

    def workflow
      @my_little_machine ||= Fiber.new do
        loop do
          value = supply && supply.shift
          Fiber.yield @task.call(value, supply, @context)
        end
      end
    end

    def default_task
      Proc.new { |value| value }
    end

    def task_accepts_a_value?
      @task.arity > 0
    end

    def task_method_exists?
      self.methods.include? :task
    end

    def task_method_accepts_a_value?
      self.method(:task).arity > 0
    end

  end

  class WorkerError < StandardError; end
end
