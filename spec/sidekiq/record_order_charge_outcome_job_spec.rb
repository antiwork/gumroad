# frozen_string_literal: true

require "spec_helper"

describe RecordOrderChargeOutcomeJob do
  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:order) { create(:order) }

  it "records the order's partial-success outcome" do
    succeeded = create(:purchase_in_progress, link: create(:product, user: seller_1), seller: seller_1)
    failed = create(:purchase_in_progress, link: create(:product, user: seller_2), seller: seller_2)
    order.purchases << succeeded << failed
    succeeded.update_balance_and_mark_successful!
    Purchase::MarkFailedService.new(failed).perform

    described_class.new.perform(order.id)

    expect(order.reload).to be_partially_successful
  end

  it "sticks the connection to the primary before reading the sibling states" do
    steps = []
    allow(ActiveRecord::Base.connection).to receive(:stick_to_primary!).and_wrap_original do |method, *args|
      steps << :stick_to_primary
      method.call(*args)
    end
    allow_any_instance_of(Order).to receive(:record_charge_outcome!).and_wrap_original do |method, *args|
      steps << :read_sibling_states
      method.call(*args)
    end

    described_class.new.perform(order.id)

    expect(steps.index(:stick_to_primary)).to be < steps.index(:read_sibling_states)
  end

  it "does not raise when the order no longer exists" do
    id = order.id
    order.destroy!

    expect { described_class.new.perform(id) }.not_to raise_error
  end
end
