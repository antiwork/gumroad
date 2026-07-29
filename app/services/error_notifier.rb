# frozen_string_literal: true

class ErrorNotifier
  class << self
    def notify(exception_or_message, exclude_request_context: false, **context, &block)
      notify_sentry(exception_or_message, exclude_request_context:, **context, &block)
    end

    private
      def notify_sentry(exception_or_message, exclude_request_context:, **context, &block)
        if exception_or_message.is_a?(Exception)
          Sentry.capture_exception(exception_or_message) do |scope|
            apply_sentry_scope(scope, context, exclude_request_context:, &block)
          end
        else
          Sentry.capture_message(exception_or_message.to_s) do |scope|
            apply_sentry_scope(scope, context, exclude_request_context:, &block)
          end
        end
      end

      def apply_sentry_scope(scope, context, exclude_request_context:, &block)
        if exclude_request_context
          # sentry-ruby applies this block to a copy of the current scope. Clear that copy because
          # request data can live in its Rack env, breadcrumbs, and active span. This leaves the
          # request's ambient scope intact and restores only the explicit safe context below.
          scope.clear
        end

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
