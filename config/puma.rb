# frozen_string_literal: true

# Puma can serve each request in a thread from an internal thread pool.
# The `threads` method setting takes two numbers a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma. Default is set to 5 threads for minimum
# and maximum, this matches the default thread size of Active Record.
#
# See unicorn migration guide: https://github.com/puma/puma/blob/master/docs/deployment.md#migrating-from-unicorn
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 2 }.to_i
threads threads_count, threads_count

# Specifies the `worker_timeout` threshold that Puma will use to wait before
# terminating a worker in development environments.
#
worker_timeout 3600 if ENV.fetch("RAILS_ENV", "development") == "development"

# Specifies the `port` that Puma will listen on to receive requests, default is 3000.
#
# Spelled as `bind` rather than `port` only because the backlog has to ride on the query
# string -- the `port` DSL builds a bare tcp:// URI, so it always takes Puma's default
# backlog of 1024. That queue is shared by every worker and drained by workers * threads
# request slots, so a burst of slow requests fills it in seconds; past that the kernel
# drops SYNs and nginx reports a connect timeout. 4096 matches the listen backlog nginx
# uses out front, and somaxconn clamps both to the same ceiling.
bind "tcp://0.0.0.0:#{ENV.fetch("PORT") { 3000 }}?backlog=4096"

# Specifies the `environment` that Puma will run in.
#
env = ENV.fetch("RAILS_ENV") { "development" }
environment env

if env != "development"
  # Specifies the number of `workers` to boot in clustered mode.
  # Workers are forked webserver processes. If using threads and workers together
  # the concurrency of the application would be max `threads` * `workers`.
  # Workers do not work on JRuby or Windows (both of which do not support
  # processes).
  #
  # workers ENV.fetch("WEB_CONCURRENCY") { 2 }
  workers ENV.fetch("PUMA_WORKER_PROCESSES") { 1 }

  # Use the `preload_app!` method when specifying a `workers` number.
  # This directive tells Puma to first boot the application and load code
  # before forking the application. This takes advantage of Copy On Write
  # process behavior so workers use less memory. If you use this option
  # you need to make sure to reconnect any threads in the `on_worker_boot`
  # block.
  #
  preload_app!

  # No `on_worker_boot` reconnect. Rails 7.2 discards every pool after a fork
  # (ActiveSupport::ForkTracker, connection_adapters/pool_config.rb), so the old
  # ActiveRecord::Base.establish_connection here was already redundant — and it is
  # now actively harmful: ApplicationRecord.connects_to shares ActiveRecord::Base's
  # pool, so re-establishing hands `connection_class` back to ActiveRecord::Base and
  # mysql2_proxy stops honoring ApplicationRecord.connected_to(role: :writing).

  # Some deploys see the container outlive its 30 s kill timeout after "Gracefully shutting
  # down workers...". These two lines show whether a worker's server, a worker's exit, or the
  # master is what waits.
  on_worker_shutdown do |index|
    $stdout.syswrite("puma_shutdown event=worker_server_stopped worker=#{index} pid=#{Process.pid} at=#{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")}\n")
  end

  on_stopped do
    $stdout.syswrite("puma_shutdown event=master_workers_reaped pid=#{Process.pid} at=#{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")}\n")
  end

  # Some workers never log worker_server_stopped and are killed at the container's kill
  # timeout. Server#stop runs from the worker's TERM trap, so a stuck worker without the
  # first line never ran its trap; one with it waits inside the graceful shutdown, and the
  # thread dump shows on what. Workers that exit normally are gone before the dump.
  shutdown_dump_after_seconds = 3
  shutdown_dump_frames = 15
  require "puma/server"
  Puma::Server.prepend(Module.new do
    define_method(:stop) do |*args|
      # The master repeats its TERM while the worker waits.
      return super(*args) if @shutdown_trace_started
      @shutdown_trace_started = true
      pid = Process.pid
      $stdout.syswrite("puma_shutdown event=worker_stop_requested pid=#{pid} at=#{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")}\n")
      Thread.new do
        sleep shutdown_dump_after_seconds
        threads = Thread.list - [Thread.current]
        threads.each_with_index do |thread, i|
          $stdout.syswrite("puma_shutdown event=worker_still_running pid=#{pid} thread=#{i + 1}/#{threads.size} name=#{thread.name.inspect} status=#{thread.status.inspect}\n")
          Array(thread.backtrace).first(shutdown_dump_frames).each do |frame|
            $stdout.syswrite("puma_shutdown event=thread_frame pid=#{pid} thread=#{i + 1} #{frame}\n")
          end
        end
      end
      super(*args)
    end
  end)
end

pidfile "tmp/pids/puma.pid"

# Allow puma to be restarted by `rails restart` command.
plugin :tmp_restart

#
# Custom Config
#

root_config = {
  development: File.expand_path("."),
  staging: "/app/",
  production: "/app/"
}
root_dir = ENV["PUMA_ROOT"] || root_config[env.to_sym]
directory root_dir
