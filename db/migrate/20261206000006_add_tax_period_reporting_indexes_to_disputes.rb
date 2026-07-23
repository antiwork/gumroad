# frozen_string_literal: true

class AddTaxPeriodReportingIndexesToDisputes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The tax-period chargeback scopes (Purchase.chargebacks_for_tax_period_reporting and
    # .chargeback_reversals_for_tax_period_reporting, shared by every sales-tax report job)
    # select one day's or month's charged-back purchases. They used to filter the very large
    # purchases table by purchases.chargeback_date, which has no standalone index — only a
    # seller_id-leading composite, unusable for an all-sellers date range — so MySQL fell back
    # to a full table scan.
    #
    # The scopes now resolve those purchases through the much smaller disputes table instead:
    # chargeback_date mirrors the dispute's event_created_at (both are set from the same
    # processor event when the dispute is formalized), and reversals are dated by
    # disputes.won_at. Those two columns were also only covered by seller_id-leading
    # composites, so give each a standalone index to make the date-range lookup a fast range
    # scan.
    change_table :disputes, bulk: true do |t|
      t.index :event_created_at, name: "index_disputes_on_event_created_at"
      t.index :won_at, name: "index_disputes_on_won_at"
    end
  end
end
