# frozen_string_literal: true

## Will check replicas for lag every second, and sleep for a few seconds if they are.
#
# Typical usage:
#   Model.find_each do |record|
#     ReplicaLagWatcher.watch
#     record.update!(field: new_value)
#   end
# Try to not update/delete more than ~1000 rows at once between checks,
# otherwise the check will happen too late to prevent a large lag.
# Example:
#   Model.in_batches do |relation| # default batch size is 1_000
#     ReplicaLagWatcher.watch
#     relation.update_all(field: new_value)
#   end
class ReplicaLagWatcher
  DEFAULT_OPTIONS = {
    check_every: 1, # prevents from spamming the replicas with queries checking their lag
    sleep: 1, # duration of sleep when lagging
    max_lag_allowed: 1, # if lag (always an integer) is superior to this, we will sleep
    silence: false # outputs which replica is lagging, by how much, and how long we're sleeping for
  }.freeze

  class << self
    def watch(options = nil)
      # skip if there are no replicas to monitor
      return if REPLICAS_HOSTS.empty?

      options = options.nil? ? DEFAULT_OPTIONS : DEFAULT_OPTIONS.merge(options)
      connect_to_replicas

      while lagging?(options)
        sleep_duration = options.fetch(:sleep)
        puts("sleeping #{sleep_duration} #{"second".pluralize(sleep_duration)}") unless options[:silence]
        sleep sleep_duration
      end
    end

    def lagging?(options)
      return unless check_for_lag?(options.fetch(:check_every))

      self.last_checked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      connections.each do |connection|
        lag = connection.query("SHOW SLAVE STATUS").to_a[0]["Seconds_Behind_Master"]
        raise("#{connection.query_options[:host]} lag = null. Is this replica available and replicating?") if lag.nil?
        if lag > options.fetch(:max_lag_allowed)
          puts("#{connection.query_options[:host]} lag = #{lag} #{"second".pluralize(lag)}") unless options[:silence]
          return true
        end
      end

      false
    end

    def check_for_lag?(check_every)
      # check lag if this is the first time we run this
      return true if last_checked_at.nil?
      # check if grace period has expired
      (last_checked_at + check_every) <= Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def connect_to_replicas
      # skip if we're already connected to replicas
      return unless connections.nil?

      self.connections = REPLICAS_HOSTS.map do |host|
        common_options = ActiveRecord::Base.connection_db_config.configuration_hash.slice(:username, :password, :database)
        Mysql2::Client.new(**common_options.merge(host:))
      end
    end

    [:connections, :last_checked_at].each do |accessor_name|
      define_method(accessor_name) do
        Thread.current["#{name}.#{accessor_name}"]
      end
      define_method("#{accessor_name}=") do |new_value|
        Thread.current["#{name}.#{accessor_name}"] = new_value
      end
    end
  end
end
