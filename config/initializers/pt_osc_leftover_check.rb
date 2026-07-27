# frozen_string_literal: true

# Refuse to run migrations against a table that still carries pt-online-schema-change
# leftovers, and say so loudly.
#
# The check itself, and why it matters, is documented on PtOscLeftovers. This file is
# only the wiring: run it once, at the start of the migration phase, before any
# migration has had a chance to fail obscurely.
#
# It is attached to Alterity's `before_running_migrations` hook rather than to a
# Rake task, so it covers everything that migrates through Alterity -- the deploy's
# `rake db:migrate`, a manual `db:migrate`, and `db:migrate:up` -- without needing
# each entry point to remember it.
#
# Skipped when:
#
#   - Alterity is disabled (DISABLE_ALTERITY), because then no pt-osc run happens and
#     leftover triggers do not block a plain ALTER. The leftovers are still costing
#     duplicated writes, so a warning is printed rather than nothing.
#   - ALLOW_PT_OSC_LEFTOVERS is set, for the one legitimate case: deploying while a
#     pt-osc run really is in flight on some other table.
#   - The database cannot be reached, or information_schema cannot be read. A check
#     that cannot run must not be the reason a deploy fails; it says so and gets out
#     of the way.
#
# Local and test environments are covered too. It costs two information_schema reads,
# and a developer whose local pt-osc run was interrupted has exactly the same problem
# as production, minus the deploy. In the RSpec suite the check itself is inert unless
# PT_OSC_LEFTOVER_CHECK_IN_TESTS is set, so a leftover from a developer's own
# interrupted run cannot redden an unrelated spec run -- but the hook is always
# installed, so the wiring is exercised rather than only the pieces.
Rails.application.config.after_initialize do
  Alterity.singleton_class.prepend(Module.new do
    def before_running_migrations
      PtOscLeftoverCheck.run!
      super
    end
  end)
end

module PtOscLeftoverCheck
  class LeftoversPresent < StandardError; end

  class << self
    def run!
      return unless enabled?
      return if ENV["ALLOW_PT_OSC_LEFTOVERS"].present?

      leftovers = detect
      return if leftovers.blank?

      message = PtOscLeftovers.failure_message(leftovers)

      if alterity_disabled?
        # A plain ALTER is not blocked by the leftover triggers, so this is not a
        # reason to stop the migration -- but the leftovers are still duplicating
        # every write to those tables, and this is the one moment somebody is
        # reading the output.
        Rails.logger.warn("[pt-osc leftovers] #{message}")
        warn("[pt-osc leftovers] Alterity is disabled, so this migration is not blocked, but:\n#{message}")
        return
      end

      Rails.logger.error("[pt-osc leftovers] #{message}")
      raise LeftoversPresent, message
    end

    private
      # The check is inert in the RSpec suite unless explicitly switched on. A
      # developer's own interrupted local pt-osc run would otherwise fail every spec
      # that migrates, which is a long way from the problem being solved.
      def enabled?
        !Rails.env.test? || ENV["PT_OSC_LEFTOVER_CHECK_IN_TESTS"].present?
      end

      def detect
        PtOscLeftovers.all
      rescue ActiveRecord::ActiveRecordError, Mysql2::Error => e
        # Cannot read information_schema. Deploys must not fail because a check
        # could not run, so this reports and continues -- the migration itself will
        # fail if the leftovers really are there.
        warn("[pt-osc leftovers] Could not check for pt-osc leftovers (#{e.class}: #{e.message}); continuing.")
        nil
      end

      def alterity_disabled?
        Alterity.state.disabled
      rescue StandardError
        false
      end
  end
end
