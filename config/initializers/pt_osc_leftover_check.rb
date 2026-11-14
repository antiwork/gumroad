# frozen_string_literal: true

# Refuse schema changes to tables carrying pt-online-schema-change triggers (see PtOscLeftovers);
# migrations on other tables still run. Statements are checked ahead of Alterity's `disabled`
# short-circuit, so plain ALTERs inside `Alterity.disable` blocks are caught too.
Rails.application.config.after_initialize do
  Alterity.singleton_class.prepend(Module.new do
    def before_running_migrations
      PtOscLeftoverCheck.run!
      super
    end

    def process_sql_query(sql, &block)
      PtOscLeftoverCheck.check_statement!(sql)
      super
    end

    def after_running_migrations
      PtOscLeftoverCheck.reset!
      super
    end
  end)
end

module PtOscLeftoverCheck
  class LeftoversPresent < StandardError; end

  SCHEMA_CHANGE_PATTERN = %r{\A(?:\s|--[^\n]*\n|/\*.*?\*/)*(?:ALTER|CREATE|DROP|RENAME|TRUNCATE)\b}im

  class << self
    def run!
      reset!
      return unless enabled?

      leftovers = detect
      return if leftovers.blank?

      @blocking = leftovers.select(&:triggers?)
      message = PtOscLeftovers.warning_message(leftovers)
      Rails.logger.warn("[pt-osc leftovers] #{message}")
      warn("[pt-osc leftovers] #{message}")
    end

    def check_statement!(sql)
      return if @blocking.blank?
      return unless SCHEMA_CHANGE_PATTERN.match?(sql)

      # `_` is a word character, so cleanup of `_<table>_new` and pt-osc's own triggers isn't refused.
      leftover = @blocking.find { |candidate| sql.match?(/(?<![\w$])#{Regexp.escape(candidate.table)}(?![\w$])/) }
      return unless leftover

      message = PtOscLeftovers.refusal_message(leftover)
      Rails.logger.error("[pt-osc leftovers] #{message}")
      raise LeftoversPresent, message
    end

    def reset!
      @blocking = []
    end

    private
      # Inert in the RSpec suite unless switched on, so a developer's interrupted local
      # pt-osc run can't redden unrelated specs.
      def enabled?
        !Rails.env.test? || ENV["PT_OSC_LEFTOVER_CHECK_IN_TESTS"].present?
      end

      # A check that can't run must not be the reason a deploy fails.
      def detect
        PtOscLeftovers.all
      rescue ActiveRecord::ActiveRecordError, Mysql2::Error => e
        warn("[pt-osc leftovers] Could not check for pt-osc leftovers (#{e.class}: #{e.message}); continuing.")
        nil
      end
  end
end
