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
    order # other code sticks to the primary while the fixtures are built, so count only `perform`
    calls = 0
    allow(ApplicationRecord).to receive(:connected_to).and_wrap_original do |method, **kwargs, &block|
      calls += 1
      method.call(**kwargs, &block)
    end

    described_class.new.perform(order.id)

    expect(calls).to eq(1)
  end

  it "does not raise when the order no longer exists" do
    id = order.id
    order.destroy!

    expect { described_class.new.perform(id) }.not_to raise_error
  end
end
