# frozen_string_literal: true

# Intentionally a no-op.
#
# This originally added a `reassignment_locked_at` column to `purchases`. That
# table is far too large for a deploy-time `ALTER TABLE`: db:migrate runs on the
# critical path of every production deploy (gr_deploy -> wait_for_db_migrate
# blocks until it finishes), and a plain ALTER on `purchases` either stalls
# behind the table's metadata lock or falls back to a full-table rebuild,
# hanging the deploy and risking a query pileup on a table written by every sale.
#
# The reassignment lock now lives in its own `purchase_reassignment_locks` table
# (see CreatePurchaseReassignmentLocks / PurchaseReassignmentLock), per the rule
# that the `users` and `purchases` tables must not take schema changes. This
# migration stays so the version records cleanly across environments; it
# performs no work.
#
# If an earlier deploy already added the column in some environment, the
# reassignment guard keeps honoring locks stored on it (Purchase::ReassignByEmailService
# dual-reads during the transition), so nothing slips through. Run
# Onetime::BackfillPurchaseReassignmentLocks to move those locks into the new
# table; afterward the column is a harmless unused nullable column that can be
# dropped out-of-band — never via a deploy-time migration.
class AddReassignmentLockedAtToPurchases < ActiveRecord::Migration[7.1]
  def up
  end

  def down
  end
end
