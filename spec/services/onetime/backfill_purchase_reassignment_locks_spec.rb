# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillPurchaseReassignmentLocks do
  describe ".process" do
    # In every environment past this change the legacy `reassignment_locked_at`
    # column is gone (the migration that added it is now a no-op), so the task
    # must short-circuit rather than query a column that doesn't exist.
    context "when the legacy reassignment_locked_at column is absent" do
      it "makes no changes and does not raise" do
        create(:free_purchase)

        expect { described_class.process }.not_to change(PurchaseReassignmentLock, :count)
      end
    end
  end
end
