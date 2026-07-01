# frozen_string_literal: true

# Intentionally a no-op.
#
# This originally added a `reassignment_locked_at` column to `purchases`. That
# table is far too large for a deploy-time `ALTER TABLE`: db:migrate runs on the
# critical path of every production deploy, and a plain ALTER on `purchases`
# stalls behind the table's metadata lock (or falls back to a full rebuild),
# hanging the deploy — which is what happened on the deploy that shipped this.
#
# The reassignment lock is now a FlagShihTzu flag on the existing `purchases.flags`
# column (Purchase#is_reassignment_locked?), so no schema change is needed. This
# migration stays as a no-op so the version records cleanly across environments.
#
# There is nothing to backfill into the flag: the ALTER was cancelled before it
# committed in production (verified — the column and this migration version are
# absent there) and the lock has no automated writer, so no purchase was ever
# locked via the column. Every row therefore starts correctly unlocked (flag bit
# defaults to 0). If some other environment did add the column, it is a harmless
# unused nullable column, to be dropped out-of-band — never via a deploy-time
# migration.
class AddReassignmentLockedAtToPurchases < ActiveRecord::Migration[7.1]
  def up
  end

  def down
  end
end
