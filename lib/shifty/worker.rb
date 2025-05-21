require "ostruct"
require "shifty/taggable"

module Shifty
  # Shifty::Worker uses Ruby Fibers for cooperative multitasking.
  # This results in a single-threaded execution model where workers
  # explicitly yield control to one another. This model is chosen for its
  # simplicity and suitability for creating chainable data processing
  # pipelines, where each worker performs a specific task and passes
  # its output to the next worker in the chain.
  class Worker
    attr_reader :supply, :tags

    include Shifty::Taggable

    def initialize(p = {}, &block)
      @supply       = p[:supply]
      @task         = block || p[:task]
      @context      = p[:context] || OpenStruct.new
      self.criteria = p[:criteria]
      self.tags     = p[:tags]
    end

    def shift
      ensure_ready_to_work!
      workflow.resume
    end

    def ready_to_work?
      @task && (supply || !task_accepts_a_value?)
    end

    def supplies(subscribing_worker)
      subscribing_worker.supply = self
      subscribing_worker
    end
    alias_method :|, :supplies

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
      # This is the core of the worker's execution, managed by a Fiber.
      # The Fiber allows the worker to pause its execution (yield) and
      # be resumed later, enabling cooperative multitasking.
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

    # ## Concurrency and Thread Safety
    #
    # ### Concurrency Model
    # Shifty utilizes Ruby Fibers to achieve cooperative multitasking. This means
    # that workers voluntarily yield control, allowing other workers to execute.
    # The entire processing pipeline runs within a single thread, simplifying
    # state management and avoiding many common concurrency issues.
    #
    # ### Alternatives (Threads/Ractors)
    # While Ruby's Threads could be used for parallelism, especially for I/O-bound
    # tasks, and Ractors (in Ruby 3.0+) for CPU-bound tasks, they would
    # introduce significant complexity. Managing thread safety with Threads
    # (e.g., using mutexes, avoiding race conditions) or adhering to Ractor's
    # message passing and object sharing restrictions would make the framework
    # harder to use and reason about. The current Fiber-based model aligns
    # well with Shifty's primary goal of providing an easy-to-use framework
    # for building sequential data processing pipelines.
    #
    # ### Thread Safety
    # `Shifty::Worker` instances, and by extension `Shifty::Gang` or
    # `Shifty::Roster` instances that manage these workers, are **not**
    # inherently thread-safe if they are shared and modified across multiple
    # user-created native threads. If users choose to integrate Shifty components
    # into a multi-threaded application (e.g., processing multiple independent
    # Shifty pipelines in parallel using separate Threads), they are responsible
    # for implementing appropriate synchronization mechanisms (like mutexes)
    # to protect shared Shifty objects from concurrent access and modification.
    # For typical use cases where a Shifty pipeline is built and run, no
    # external threading is usually involved by the user.
  end

  class WorkerError < StandardError; end
end
