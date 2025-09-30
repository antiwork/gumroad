# frozen_string_literal: true

require "spec_helper"

RSpec.describe Purchase, type: :model do
  describe "installment schedule snapshot" do
    it "uses snapshot on the purchase when present and ignores later product changes" do
      product = build(:product, :with_installment_plan, price_cents: 19_700, native_type: Link::NATIVE_TYPE_DIGITAL)
      original_purchase = Purchase.new(link: product, displayed_price_cents: 19_700)
      original_purchase.is_installment_payment = true
      original_purchase.installment_plan = product.installment_plan
      original_purchase.installment_payment_schedule_cents = [9_900, 9_800]

      subscription = Subscription.new(link: product, is_installment_plan: true)
      allow(subscription).to receive_message_chain(:purchases, :successful, :count).and_return(1)
      allow(subscription).to receive(:original_purchase).and_return(original_purchase)

      next_charge = Purchase.new(link: product, displayed_price_cents: 19_700, subscription: subscription)
      next_charge.is_installment_payment = true
      next_charge.installment_plan = product.installment_plan

      # Should take the 2nd entry of the snapshot (index 1)
      expect(next_charge.send(:calculate_installment_payment_price_cents, 19_700)).to eq(9_800)

      # Mutate product/plan and ensure snapshot still rules
      product.price_cents = 99_999
      product.installment_plan.number_of_installments = 3
      expect(next_charge.send(:calculate_installment_payment_price_cents, 19_700)).to eq(9_800)
    end

    it "falls back to original_purchase snapshot when current purchase has none" do
      product = build(:product, :with_installment_plan, price_cents: 19_700, native_type: Link::NATIVE_TYPE_DIGITAL)
      original_purchase = Purchase.new(link: product, displayed_price_cents: 19_700)
      original_purchase.is_installment_payment = true
      original_purchase.installment_plan = product.installment_plan
      original_purchase.installment_payment_schedule_cents = [10_000, 9_700]

      subscription = Subscription.new(link: product, is_installment_plan: true)
      allow(subscription).to receive_message_chain(:purchases, :successful, :count).and_return(1)
      allow(subscription).to receive(:original_purchase).and_return(original_purchase)

      next_charge = Purchase.new(link: product, displayed_price_cents: 19_700, subscription: subscription)
      next_charge.is_installment_payment = true
      next_charge.installment_plan = product.installment_plan

      expect(next_charge.send(:calculate_installment_payment_price_cents, 19_700)).to eq(9_700)
    end
  end
end


