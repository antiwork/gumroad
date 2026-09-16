# frozen_string_literal: true

require "flipper/adapters/wrapper"

module Flipper
  module Adapters
    class RedisFailOpen < Wrapper
      MAX_FEATURES = 1_000
      REPORT_INTERVAL = 60
      READS = %i[get get_multi get_all features].freeze
      WRITES = %i[add remove clear enable disable import].freeze

      State = Struct.new(:lock, :values, :features, :last_reported_at, :generation) do
        def initialize
          super(Mutex.new, {}, nil, nil, 0)
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

        generation = @state.lock.synchronize { @state.generation }
        result = yield
        @state.lock.synchronize { remember(operation, args, result) if generation == @state.generation }
        result
      rescue ::Redis::BaseError, RedisClient::Error => error
        raise unless READS.include?(operation)

        report(error)
        @state.lock.synchronize { fallback(operation, args, error).deep_dup }
      ensure
        invalidate(args.first) if WRITES.include?(operation)
      end

      private
        def remember(operation, args, result)
          case operation
          when :get
            @state.values[args.first.key] = result.deep_dup
            @state.features = nil if @state.features && !@state.features.include?(args.first.key)
          when :get_multi
            @state.values.merge!(result.deep_dup)
            @state.features = nil if @state.features && result.any? { |key, _| !@state.features.include?(key) }
          when :get_all
            @state.values = result.deep_dup
          when :features
            @state.features = result.size <= MAX_FEATURES ? result.dup : nil
            @state.values.select! { |key, _| result.include?(key) }
          end
          @state.values.shift while @state.values.size > MAX_FEATURES
          @state.features = result.size <= MAX_FEATURES ? result.keys.to_set : nil if operation == :get_all
        end

        def fallback(operation, args, error)
          # Unknown flags can enforce tax collection or webhook verification.
          case operation
          when :get
            @state.values.fetch(args.first.key) { raise error }
          when :get_multi
            args.first.to_h { |feature| [feature.key, @state.values.fetch(feature.key) { raise error }] }
          when :get_all
            keys = @state.features || raise(error)
            keys.index_with { |key| @state.values.fetch(key) { raise error } }
          when :features
            @state.features || raise(error)
          end
        end

        def invalidate(feature)
          @state.lock.synchronize do
            # Fence reads spanning a write, including writes whose replies time out.
            @state.generation += 1
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
