# frozen_string_literal: true

# Try MySQL 8.0 ALGORITHM=INSTANT before handing a schema change to
# pt-online-schema-change.
#
# Alterity routes every ALTER through pt-osc (config/initializers/alterity.rb),
# which is the right default for anything that has to rebuild the table. But a
# plain ADD COLUMN on MySQL 8.0 is a metadata-only change: it touches no rows and
# finishes in milliseconds regardless of table size. Sending it through pt-osc
# instead means copying the whole table.
#
# That is not just slow, it is the failure mode. On product_reviews (~6.9M rows,
# ~1GB) the copy ran past the deployer's ~31min migration wait, a following merge
# replaced the Nomad migration job mid-copy, and the killed run left its three
# triggers and `_product_reviews_new` behind. PtOscLeftoverCheck then correctly
# refused every subsequent migration and production deploys were blocked for
# hours with 24 merged commits undeployed (antiwork/gumroad-private#1810). The
# ALTER that caused it was:
#
#   ADD COLUMN seller_notified_at datetime(6)
#
# measured at 2.6ms with ALGORITHM=INSTANT. There was no row copy to interrupt,
# so there was nothing for the interruption to leave behind.
#
# WHY TRYING IS SAFE. MySQL validates ALGORITHM=INSTANT during ALTER preparation
# and refuses the whole statement atomically before modifying anything:
#
#   ADD INDEX          -> ERROR 1845 ALGORITHM=INSTANT is not supported for this operation
#   MODIFY column type -> ERROR 1846 ... Need to rebuild the table to change column type
#
# So there is no half-applied state to reason about: either the change is already
# done, or nothing happened and pt-osc runs exactly as it does today. The same
# applies when a table exhausts its instant-column budget (InnoDB allows a bounded
# number of instant additions before a rebuild is required) -- that surfaces as the
# same refusal and takes the same fallback path.
#
# The attempt runs with a short lock_wait_timeout, matching pt-osc's
# `--set-vars lock_wait_timeout=1`, so a busy table cannot make the probe itself
# the thing that hangs a deploy. A timeout is treated as "could not do it
# instantly" and falls through.
#
# This does not replace the leftover guard or make pt-osc unnecessary. It removes
# the class of migration that never needed pt-osc in the first place from the set
# that can strand leftovers.
Rails.application.config.after_initialize do
  next unless defined?(Alterity)

  Alterity.singleton_class.prepend(Module.new do
    private
      def execute_alter(table, updates)
        super unless InstantDdlFirst.attempt(table, updates)
      end
  end)
end

module InstantDdlFirst
  # Errors that mean "this operation cannot be done instantly". Anything else is a
  # real problem and must not be swallowed into a silent pt-osc fallback.
  #
  #   1845 ER_ALTER_OPERATION_NOT_SUPPORTED       -- operation cannot be INSTANT
  #   1846 ER_ALTER_OPERATION_NOT_SUPPORTED_REASON -- ... with a reason
  #   1205 ER_LOCK_WAIT_TIMEOUT                    -- could not get the metadata lock quickly
  #   4092 ER_INNODB_MAX_ROW_VERSION               -- instant-column budget exhausted
  NOT_INSTANT_ERROR_CODES = [1845, 1846, 1205, 4092].freeze

  class << self
    # Runs the ALTER with ALGORITHM=INSTANT. Returns true when it succeeded, false
    # when the operation cannot be instant and the caller should fall back.
    def attempt(table, updates)
      return false unless eligible?(updates)

      connection = ActiveRecord::Base.connection
      sql = "ALTER TABLE #{table} #{updates}, ALGORITHM=INSTANT"

      Alterity.disable do
        previous = connection.select_value("SELECT @@SESSION.lock_wait_timeout")
        begin
          connection.execute("SET SESSION lock_wait_timeout = 1")
          connection.execute(sql)
        ensure
          # Restore rather than leave the whole migration session at 1s, which would
          # make unrelated later statements fail for a reason nothing explains.
          connection.execute("SET SESSION lock_wait_timeout = #{previous.to_i}") if previous
        end
      end

      log("Applied instantly, skipping pt-online-schema-change: ALTER TABLE #{table} #{updates}")
      true
    rescue ActiveRecord::StatementInvalid => e
      raise unless not_instant?(e)

      log("Not an instant operation (#{mysql_errno(e)}), falling back to pt-online-schema-change: ALTER TABLE #{table} #{updates}")
      false
    end

    private
      # Only single-clause ALTERs that do not already pin an algorithm. A
      # caller-specified ALGORITHM= must win, and appending a second one would be
      # invalid SQL. Multi-clause ALTERs are left to pt-osc: one clause being
      # instant-capable says nothing about the others, and a partial application is
      # exactly what must not happen.
      def eligible?(updates)
        text = updates.to_s
        return false if text.blank?
        return false if text.match?(/\bALGORITHM\s*=/i)
        return false if text.match?(/\bLOCK\s*=/i)
        return false if text.include?(",")

        true
      end

      def not_instant?(error)
        NOT_INSTANT_ERROR_CODES.include?(mysql_errno(error))
      end

      def mysql_errno(error)
        cause = error.cause
        cause.respond_to?(:error_number) ? cause.error_number : nil
      end

      def log(message)
        Rails.logger.info("[InstantDdlFirst] #{message}")
        puts "[InstantDdlFirst] #{message}"
      end
  end
end
