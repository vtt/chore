module Skiplock
  class Worker < ActiveRecord::Base
    self.implicit_order_column = 'updated_at'
    has_many :jobs, inverse_of: :worker

    def self.cleanup(hostname = nil)
      delete_ids = []
      self.where(hostname: hostname || Socket.gethostname).each do |worker|
        sid = Process.getsid(worker.pid) rescue nil
        delete_ids << worker.id if worker.sid != sid || worker.updated_at < 10.minutes.ago
      end
      self.where(id: delete_ids).delete_all if delete_ids.count > 0
    end

    def self.generate(capacity:, hostname:, master: true)
      self.create!(pid: Process.pid, sid: Process.getsid(), master: master, hostname: hostname, capacity: capacity)
    rescue
      self.create!(pid: Process.pid, sid: Process.getsid(), master: false, hostname: hostname, capacity: capacity)
    end

    def shutdown
      @running = false
      @executor.shutdown
      @executor.kill unless @executor.wait_for_termination(@config[:graceful_shutdown])
      self.delete
      Skiplock.logger.info "[Skiplock] Shutdown of #{self.master ? 'master' : 'cluster'} worker#{(' ' + @num.to_s) if @num > 0 && @config[:workers] > 2} (PID: #{self.pid}) was completed."
    end

    def start(worker_num: 0, **config)
      @num = worker_num
      @config = config
      @queues_order_query = @config[:queues].map { |q,v| "WHEN queue_name = '#{q}' THEN #{v}" }.join(' ') if @config[:queues].is_a?(Hash) && @config[:queues].count > 0
      @running = true
      @executor = Concurrent::ThreadPoolExecutor.new(min_threads: @config[:min_threads] + 1, max_threads: @config[:max_threads] + 1, max_queue: @config[:max_threads] + 1, idletime: 60, auto_terminate: true, fallback_policy: :discard)
      if self.master
        Job.flush
        Cron.setup
      end
      @executor.post { run }
      Process.setproctitle("skiplock: #{self.master ? 'master' : 'cluster'} worker#{(' ' + @num.to_s) if @num > 0 && @config[:workers] > 2} [#{Rails.application.class.name.deconstantize.downcase}:#{Rails.env}]") if @config[:standalone]
    end

    private

    def reloader_post
      Rails.application.reloader.wrap { @executor.post { Rails.application.executor.wrap { yield } } } if block_given?
    end

    def run
      sleep 3
      Skiplock.logger.info "[Skiplock] Starting in #{@config[:standalone] ? 'standalone' : 'async'} mode (PID: #{self.pid}) with #{@config[:max_threads]} max threads as #{self.master ? 'master' : 'cluster'} worker#{(' ' + @num.to_s) if @num > 0 && @config[:workers] > 2}..."
      error = false
      next_schedule_at = Time.now.to_f
      pg_exception_timestamp = nil
      timestamp = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.exec_query('LISTEN "skiplock::jobs"')
        while @running
          begin
            if error
              unless connection.active?
                connection.reconnect!
                sleep(0.5)
                connection.exec_query('LISTEN "skiplock::jobs"')
                reloader_post { Job.flush } if self.master
                pg_exception_timestamp = nil
                next_schedule_at = Time.now.to_f
              end
              error = false
            end
            if Time.now.to_f >= next_schedule_at && @executor.remaining_capacity > 1  # reserves 1 slot in queue for Job.flush in case of pg_connection error
              result = nil
              connection.transaction do
                result = connection.select_all("SELECT id, running, scheduled_at FROM skiplock.jobs WHERE running = FALSE AND expired_at IS NULL AND finished_at IS NULL ORDER BY scheduled_at ASC NULLS FIRST,#{@queues_order_query ? ' CASE ' + @queues_order_query + ' ELSE NULL END ASC NULLS LAST,' : ''} priority ASC NULLS LAST, created_at ASC FOR UPDATE SKIP LOCKED LIMIT 1").first
                result = connection.select_all("UPDATE skiplock.jobs SET running = TRUE, worker_id = '#{self.id}', updated_at = NOW() WHERE id = '#{result['id']}' RETURNING *").first if result && result['scheduled_at'].to_f <= Time.now.to_f
              end
              if result && result['running']
                reloader_post { Job.instantiate(result).execute(purge_completion: @config[:purge_completion], max_retries: @config[:max_retries]) }
              else
                next_schedule_at = (result ? result['scheduled_at'].to_f : Float::INFINITY)
              end
            end
            job_notifications = []
            connection.raw_connection.wait_for_notify(0.2) do |channel, pid, payload|
              job_notifications << payload if payload
              loop do
                payload = connection.raw_connection.notifies
                break unless @running && payload
                job_notifications << payload[:extra]
              end
              job_notifications.each do |n|
                op, id, worker_id, job_class, queue_name, running, expired_at, finished_at, scheduled_at = n.split(',')
                next if op == 'DELETE' || running == 'true' || expired_at.to_f > 0 || finished_at.to_f > 0
                next_schedule_at = scheduled_at.to_f if scheduled_at.to_f < next_schedule_at
              end
            end
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) - timestamp > 60
              connection.exec_query("UPDATE skiplock.workers SET updated_at = NOW() WHERE id = '#{self.id}'")
              timestamp = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          rescue Exception => ex
            Skiplock.logger.error(ex.to_s)
            Skiplock.logger.error(ex.backtrace.join("\n"))
            report_exception = true
            # if error is with database connection then only report if it persists longer than 1 minute
            if ex.is_a?(::PG::ConnectionBad)
              report_exception = false if pg_exception_timestamp.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) - pg_exception_timestamp <= 60
              pg_exception_timestamp ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
            Skiplock.on_errors.each { |p| p.call(ex) } if report_exception
            error = true
            wait(5)
          end
          sleep(0.3)
        end
        connection.exec_query('UNLISTEN *')
      end
    end

    def wait(timeout)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      while @running
        sleep(0.5)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - t > timeout
      end
    end
  end
end