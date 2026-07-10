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
    attr_reader :supply, :tags, :name
    attr_accessor :pipeline_policy

    include Shifty::Taggable
    include Shifty::PolicyDeclarable

    def initialize(p = {}, &block)
      @supply       = p[:supply]
      @task         = block || p[:task]
      @context      = p[:context] || OpenStruct.new
      @policy       = Policy.validate!(p[:policy]) if p[:policy]
      @name         = p[:name]
      self.criteria = p[:criteria]
      self.tags     = p[:tags]
    end

    def effective_policy
      @policy || pipeline_policy || Shifty.config.default_policy
    end

    # Applies this worker's effective policy to a value crossing its
    # boundary. Public because Policy::Supply routes a task's own
    # supply.shift calls back through it.
    def intake(value)
      Policy.resolve(effective_policy).call(value, worker: self)
    end

    def shift
      ensure_ready_to_work!
      workflow.resume
    rescue PolicyError
      # The raising Fiber is terminated and can never be resumed; discard
      # it so a caller that rescues the violation can keep shifting.
      # Closure and context state survive — only the loop restarts.
      @my_little_machine = nil
      raise
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
      #
      # Handoff policy is applied at intake — the moment this worker pulls
      # a value across its boundary — which is the single seam every value
      # crosses regardless of how many times an upstream task yielded.
      @my_little_machine ||= Fiber.new {
        loop do
          value = intake(supply&.shift)
          if criteria_passes?
            Fiber.yield perform_task(value)
          else
            Fiber.yield value
          end
        end
      }
    end

    def perform_task(value)
      @task.call(value, policy_supply, @context)
    rescue FrozenError => e
      raise PolicyViolation.new(
        worker: self,
        policy: effective_policy,
        receiver: e.receiver,
        value: value,
        cause: e
      )
    end

    def policy_supply
      supply && Policy::Supply.new(supply, self)
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
    # The entire processing pipeline runs within a single thread, which removes
    # an entire class of *preemptive* concurrency hazards (races on shared
    # objects, the need for mutexes around Shifty's own state).
    #
    # Note that single-threading does NOT make the data flowing between workers
    # safe on its own: because each value passes through every worker before the
    # next value begins, a worker that mutates a handed-off value can silently
    # corrupt what downstream workers observe. That hazard is orthogonal to
    # threading and is addressed separately by handoff immutability policies
    # (see docs/planning/handoff-immutability-policies.md).
    #
    # ### Alternatives (Threads/Ractors)
    # Threads and Ractors are not used for parallelism *yet*. Shifty's current
    # goal is an easy-to-use framework for sequential data pipelines, and a
    # single-threaded Fiber model serves that directly without the overhead of
    # mutexes (Threads) or the sharing restrictions of Ractors. This is a
    # scoping decision, not a rejection: the planned move to deeply frozen,
    # shareable handoff values is deliberately Ractor-compatible and lays the
    # groundwork for a future Ractor-backed worker type. (Fibers cannot cross
    # Ractor boundaries, so such a worker would be a distinct type, not a
    # retrofit of this one.)
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
    # (Handoff immutability policies govern only the *values* passed between
    # workers, not the worker/pipeline objects themselves or their closure
    # state — those remain the user's responsibility across threads.)
    # For typical use cases where a Shifty pipeline is built and run, no
    # external threading is usually involved by the user.
  end
end
