# frozen_string_literal: true

module GoodJob
  # A GoodJob::Capsule contains the resources necessary to execute jobs, including
  # a {GoodJob::Scheduler}, {GoodJob::Poller}, {GoodJob::Notifier}, and {GoodJob::CronManager}.
  # GoodJob creates a default capsule on initialization.
  class Capsule
    # @!attribute [r] instances
    #   @!scope class
    #   List of all instantiated Capsules in the current process.
    #   @return [Array<GoodJob::Capsule>, nil]
    cattr_reader :instances, default: Concurrent::Array.new, instance_reader: false

    # @param configuration [GoodJob::Configuration] Configuration to use for this capsule.
    def initialize(configuration: GoodJob.configuration)
      @configuration = configuration
      @startable = true
      @shutdown_on_idle_enabled = false
      @running = false
      @mutex = Mutex.new

      self.class.instances << self
    end

    # Expose stats from the scheduler
    # @return [Hash] stats plucked out of all the schedulers
    def stats
      {
        active_execution_thread_count: @multi_scheduler.stats.fetch(:active_execution_thread_count, 0),
        last_job_executed_at: @multi_scheduler.stats.fetch(:execution_at, nil)
      }
    end

    # Start the capsule once. After a shutdown, {#restart} must be used to start again.
    # @return [nil, Boolean] Whether the capsule was started.
    def start(force: false)
      return unless startable?(force: force)

      @mutex.synchronize do
        return unless startable?(force: force)

        @shared_executor = GoodJob::SharedExecutor.new
        @notifier = GoodJob::Notifier.new(enable_listening: @configuration.enable_listen_notify, executor: @shared_executor.executor)
        @poller = GoodJob::Poller.new(poll_interval: @configuration.poll_interval)
        @multi_scheduler = GoodJob::MultiScheduler.from_configuration(@configuration, warm_cache_on_initialize: true)
        @notifier.recipients.push([@multi_scheduler, :create_thread])
        @poller.recipients.push(-> { @multi_scheduler.create_thread({ fanout: true }) })

        @cron_manager = GoodJob::CronManager.new(@configuration.cron_entries, start_on_initialize: true, executor: @shared_executor.executor) if @configuration.enable_cron?

        @shutdown_on_idle_enabled = @configuration.shutdown_on_idle.positive?
        @startable = false
        @running = true
      end
    end

    # Shut down the thread pool executors.
    # @param timeout [nil, Numeric, NONE] Seconds to wait for active threads.
    #   * +-1+ will wait for all active threads to complete.
    #   * +0+ will interrupt active threads.
    #   * +N+ will wait at most N seconds and then interrupt active threads.
    #   * +nil+ will trigger a shutdown but not wait for it to complete.
    # @return [void]
    def shutdown(timeout: NONE)
      timeout = @configuration.shutdown_timeout if timeout == NONE
      GoodJob._shutdown_all([@shared_executor, @notifier, @poller, @multi_scheduler, @cron_manager].compact, timeout: timeout)
      @startable = false
      @running = false
    end

    # Shutdown and then start the capsule again.
    # @param timeout [Numeric, NONE] Seconds to wait for active threads.
    # @return [void]
    def restart(timeout: NONE)
      raise ArgumentError, "Capsule#restart cannot be called with a timeout of nil" if timeout.nil?

      shutdown(timeout: timeout)
      start(force: true)
    end

    # @return [Boolean] Whether the capsule is currently running.
    def running?
      @running
    end

    # @return [Boolean] Whether the capsule has been shutdown.
    def shutdown?
      [@shared_executor, @notifier, @poller, @multi_scheduler, @cron_manager].compact.all?(&:shutdown?)
    end

    # @return [Boolean] Whether the capsule is idle
    def idle?
      return false unless @shutdown_on_idle_enabled

      seconds = @configuration.shutdown_on_idle
      last_job_executed_at = stats[:last_job_executed_at]

      last_job_executed_at.nil? || (Time.current - last_job_executed_at >= seconds)
    end


    # Creates an execution thread(s) with the given attributes.
    # @param job_state [Hash, nil] See {GoodJob::Scheduler#create_thread}.
    # @return [Boolean, nil] Whether the thread was created.
    def create_thread(job_state = nil)
      start if startable?
      @multi_scheduler&.create_thread(job_state)
    end

    private

    def startable?(force: false)
      !@running && (@startable || force)
    end
  end
end
