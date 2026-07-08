# frozen_string_literal: true

class AddFormalizedSideEffectsFinishedAtToDisputes < ActiveRecord::Migration[7.1]
  def up
    add_column :disputes, :formalized_side_effects_finished_at, :datetime

    # Backfill every dispute that was already formalized (including ones that later
    # transitioned to won/lost) so pre-existing disputes keep today's replay behavior:
    # a re-delivered "dispute formalized" webhook skips the side effects and only
    # re-enqueues the refund-policy enforcement job. The new resume-on-replay path
    # (Charge::Disputable#handle_event_dispute_formalized!) should only ever fire for
    # disputes formalized after this deploy whose side effects genuinely crashed partway.
    # Batched so the backfill never holds row locks on the whole table at once: a single
    # unbounded UPDATE could block live dispute webhook processing for its full duration.
    Dispute.where.not(formalized_at: nil).in_batches do |batch|
      batch.update_all("formalized_side_effects_finished_at = formalized_at")
    end
  end

  def down
    remove_column :disputes, :formalized_side_effects_finished_at
  end
end
