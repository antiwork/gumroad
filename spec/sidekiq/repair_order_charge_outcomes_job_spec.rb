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

  before { $redis.del(RedisKey.order_charge_outcome_repair_cursor) }

  it "flags a partial order whose reconciliation enqueue was lost" do
    order = settle_with_lost_enqueue(create(:order))
    expect(order.reload).not_to be_partially_successful

    described_class.new.perform

    expect(order.reload).to be_partially_successful
  end

  # Absolute ages throughout, not `RECENT_WINDOW.ago` — a fixture derived from the constant moves
  # with it and cannot pin any boundary at all.
  it "flags an order that settled long after checkout, past the freshness window" do
    order = settle_with_lost_enqueue(create(:order))
    order.update_column(:created_at, 30.days.ago)

    described_class.new.perform

    expect(order.reload).to be_partially_successful
  end

  it "leaves an order older than the backlog horizon alone" do
    order = settle_with_lost_enqueue(create(:order))
    order.update_column(:created_at, 120.days.ago)

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

  it "resumes the backlog walk from the saved cursor and wraps once past the end" do
    older = settle_with_lost_enqueue(create(:order))
    newer = settle_with_lost_enqueue(create(:order))
    [older, newer].each { _1.update_column(:created_at, 30.days.ago) }
    stub_const("#{described_class}::MAX_BACKLOG_SCANNED", 1)

    described_class.new.perform
    expect(older.reload).to be_partially_successful
    expect(newer.reload).not_to be_partially_successful
    expect($redis.get(RedisKey.order_charge_outcome_repair_cursor).to_i).to eq(older.id)

    described_class.new.perform
    expect(newer.reload).to be_partially_successful

    # Nothing left past the cursor, so the third run wraps rather than stalling there. Both orders
    # are flagged by now and have left the candidate set, so the wrapped page is empty and the
    # cursor stays at the start — which is what makes the next lap see a newly-stranded order.
    described_class.new.perform
    expect($redis.get(RedisKey.order_charge_outcome_repair_cursor).to_i).to eq(0)
  end

  it "reads from the primary" do
    expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original

    described_class.new.perform
  end
end
