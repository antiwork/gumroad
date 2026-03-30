# frozen_string_literal: true

class ErrorNotifier
  class << self
    def notify(exception_or_message, **context, &block)
      notify_sentry(exception_or_message, **context, &block)
    end

    private
      def notify_sentry(exception_or_message, **context, &block)
        if exception_or_message.is_a?(Exception)
          Sentry.capture_exception(exception_or_message) do |scope|
            apply_sentry_scope(scope, context, &block)
          end
        else
          Sentry.capture_message(exception_or_message.to_s) do |scope|
            apply_sentry_scope(scope, context, &block)
          end
        end
      end

      def apply_sentry_scope(scope, context, &block)
        scope.set_context(:extra, context) if context.any?
        return if block.nil?

        report = SentryReportAdapter.new(scope)
        yield report
      end
  end

  class SentryReportAdapter
    def initialize(scope)
      @scope = scope
    end

    def severity=(level)
      @scope.set_level(level)
    end

    def add_metadata(tab, data)
      @scope.set_context(tab.to_s, data)
    end

    alias_method :add_tab, :add_metadata
  end
end
