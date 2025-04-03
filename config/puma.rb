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
port ENV.fetch("PORT") { 3000 }

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

  # The code in the `on_worker_boot` will be called if you are using
  # clustered mode by specifying a number of `workers`. After each worker
  # process is booted this block will be run, if you are using `preload_app!`
  # option you will want to use this block to reconnect to any threads
  # or connections that may have been created at application boot, Ruby
  # cannot share connections between processes.
  #
  on_worker_boot do
    if defined?(ActiveRecord::Base)
      ActiveRecord::Base.establish_connection
      Makara::Context.release_all
    end
  end
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
