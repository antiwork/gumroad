# frozen_string_literal: true

require "spec_helper"

describe RepairOrderChargeOutcomesJob do
  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:product_1) { create(:product, user: seller_1) }
  let(:product_2) { create(:product, user: seller_2) }

  # Models the enqueue being lost: `update_columns` writes the terminal states without firing the
  # `after_commit` that would normally enqueue the reconciliation, so nothing writes the flag. It
  # also sidesteps the charge-path validations, which is not what this job reads.
  def settle_with_lost_enqueue(order)
    succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
    failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
    order.purchases << succeeded << failed
    succeeded.update_columns(purchase_state: "successful")
    failed.update_columns(purchase_state: "failed")
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
    # Absolute age, not `LOOKBACK.ago` — a fixture derived from the constant moves with it and
    # cannot pin the window at all.
    order = settle_with_lost_enqueue(create(:order))
    order.update_column(:created_at, 30.days.ago)

    described_class.new.perform

    expect(order.reload).not_to be_partially_successful
  end

  it "does not flag an order that is not partial" do
    order = create(:order)
    one = create(:purchase_in_progress, link: product_1, seller: seller_1)
    two = create(:purchase_in_progress, link: product_2, seller: seller_2)
    order.purchases << one << two
    one.update_columns(purchase_state: "successful")
    two.update_columns(purchase_state: "successful")
    RecordOrderChargeOutcomeJob.jobs.clear

    described_class.new.perform

    expect(order.reload).not_to be_partially_successful
  end

  it "reads from the primary" do
    expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original

    described_class.new.perform
  end
end
