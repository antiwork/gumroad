# frozen_string_literal: true

require "flipper/adapters/wrapper"

module Flipper
  module Adapters
    class RedisFailOpen < Wrapper
      MAX_FEATURES = 1_000
      REPORT_INTERVAL = 60
      READS = %i[get get_multi get_all features].freeze
      WRITES = %i[add remove clear enable disable import].freeze

      State = Struct.new(:lock, :values, :features, :last_reported_at) do
        def initialize
          super(Mutex.new, {}, nil, nil)
        end
      end

      def initialize(adapter, state: State.new)
        super(adapter)
        @state = state
      end

      def wrap(operation, *args, **kwargs)
        unless READS.include?(operation)
          invalidate(args.first) if WRITES.include?(operation)
          return yield
        end

        result = yield
        @state.lock.synchronize { remember(operation, args, result) }
        result
      rescue ::Redis::BaseError, RedisClient::Error => error
        raise unless READS.include?(operation)

        report(error)
        @state.lock.synchronize { fallback(operation, args).deep_dup }
      end

      private
        def remember(operation, args, result)
          case operation
          when :get
            @state.values[args.first.key] = result.deep_dup
          when :get_multi
            @state.values.merge!(result.deep_dup)
          when :get_all
            @state.values = result.deep_dup
            @state.features = result.keys.first(MAX_FEATURES).to_set
          when :features
            @state.features = result.first(MAX_FEATURES).to_set
            @state.values.select! { |key, _| result.include?(key) }
          end
          @state.values.shift while @state.values.size > MAX_FEATURES
        end

        def fallback(operation, args)
          case operation
          when :get
            @state.values.fetch(args.first.key) { default_config }
          when :get_multi
            args.first.to_h { |feature| [feature.key, @state.values.fetch(feature.key) { default_config }] }
          when :get_all
            keys = @state.features || @state.values.keys
            keys.index_with { |key| @state.values.fetch(key) { default_config } }
          when :features
            @state.features || @state.values.keys.to_set
          end
        end

        def invalidate(feature)
          @state.lock.synchronize do
            # A timed-out write may have applied, so do not resurrect its old gates.
            if feature.respond_to?(:key)
              @state.values.delete(feature.key)
            else
              @state.values.clear
            end
            @state.features = nil
          end
        end

        def report(error)
          notify = @state.lock.synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if @state.last_reported_at.nil? || now - @state.last_reported_at >= REPORT_INTERVAL
              @state.last_reported_at = now
              true
            end
          end
          ErrorNotifier.notify(error, context: { adapter: self.class.name }) if notify
        rescue StandardError
          # Reporting must not turn a degraded flag read back into a failed request.
          nil
        end
    end
  end
end
