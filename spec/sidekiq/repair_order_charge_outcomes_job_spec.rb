# frozen_string_literal: true

require "spec_helper"

describe RepairOrderChargeOutcomesJob do
  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:product_1) { create(:product, user: seller_1) }
  let(:product_2) { create(:product, user: seller_2) }

  # Simulates the enqueue being lost: settle both line items with the reconciliation job discarded,
  # so nothing writes the flag. `mark_successful!` rather than `update_balance_and_mark_successful!`
  # — the balance leg is not what this job reads.
  def settle_with_lost_enqueue(order)
    succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
    failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
    order.purchases << succeeded << failed
    succeeded.mark_successful!
    Purchase::MarkFailedService.new(failed).perform
    RecordOrderChargeOutcomeJob.jobs.clear
    order
  end

  it "flags a partial order whose reconciliation enqueue was lost" do
    order = settle_with_lost_enqueue(create(:order))
    expect(order.reload).not_to be_partially_successful

    described_class.new.perform

    expect(order.reload).to be_partially_successful
  end

  it "leaves an order outside the lookback window alone" do
    order = settle_with_lost_enqueue(create(:order))
    order.update_column(:created_at, described_class::LOOKBACK.ago - 1.day)

    described_class.new.perform

    expect(order.reload).not_to be_partially_successful
  end

  it "does not flag an order that is not partial" do
    order = create(:order)
    one = create(:purchase_in_progress, link: product_1, seller: seller_1)
    two = create(:purchase_in_progress, link: product_2, seller: seller_2)
    order.purchases << one << two
    one.mark_successful!
    two.mark_successful!
    RecordOrderChargeOutcomeJob.jobs.clear

    described_class.new.perform

    expect(order.reload).not_to be_partially_successful
  end

  it "reads from the primary" do
    expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original

    described_class.new.perform
  end
end
