# frozen_string_literal: true

require "spec_helper"

describe Purchase::Reportable do
  let(:product) { create(:product) }
  let(:purchase) { create(:purchase, link: product) }

  describe "#price_cents_net_of_refunds" do
    it "returns the price" do
      expect(purchase.price_cents_net_of_refunds).to eq(100)
    end
  end

  context "when the purchase is chargedback" do
    before do
      purchase.update!(chargeback_date: Time.current)
    end

    it "returns 0" do
      expect(purchase.price_cents_net_of_refunds).to eq(0)
    end
  end

  context "when the purchase is fully refunded" do
    before do
      purchase.update!(stripe_refunded: true)
    end

    it "returns 0" do
      expect(purchase.price_cents_net_of_refunds).to eq(0)
    end
  end

  context "when the purchase is partially refunded" do
    before do
      purchase.update!(stripe_partially_refunded: true)
    end

    context "when the refunds don't have amounts" do
      before do
        create(:refund, purchase:, amount_cents: 0)
      end

      it "returns the price" do
        expect(purchase.price_cents_net_of_refunds).to eq(100)
      end
    end

    context "when refunds have amounts" do
      before do
        2.times do
          create(:refund, purchase:, amount_cents: 10)
        end
      end

      it "returns the price minus refunded amount" do
        expect(purchase.price_cents_net_of_refunds).to eq(80)
      end
    end
  end

  describe "#price_cents_for_tax_reporting" do
    let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }

    context "for a purchase created before the refund reporting cutover" do
      let(:purchase) do
        create(:purchase, link: product).tap { |p| p.update_column(:created_at, cutover.beginning_of_day - 30.days) }
      end

      it "returns the price when nothing was refunded" do
        expect(purchase.price_cents_for_tax_reporting).to eq(100)
      end

      it "nets only pre-cutover refunds, leaving post-cutover refunds to the refund leg" do
        create(:refund, purchase:, amount_cents: 10).update_column(:created_at, cutover.beginning_of_day - 10.days)
        create(:refund, purchase:, amount_cents: 25).update_column(:created_at, cutover.beginning_of_day + 10.days)
        purchase.update!(stripe_partially_refunded: true)

        # Only the pre-cutover 10 is netted; the post-cutover 25 is reported as its own
        # refund row in the period it happened, so netting it here would double-count it.
        expect(purchase.price_cents_for_tax_reporting).to eq(90)
      end

      it "returns 0 when fully refunded pre-cutover" do
        create(:refund, purchase:, amount_cents: 100).update_column(:created_at, cutover.beginning_of_day - 10.days)
        purchase.update!(stripe_refunded: true)

        expect(purchase.price_cents_for_tax_reporting).to eq(0)
      end
    end

    context "for a purchase created on/after the refund reporting cutover" do
      let(:purchase) do
        create(:purchase, link: product).tap { |p| p.update_column(:created_at, cutover.beginning_of_day + 1.day) }
      end

      it "returns the gross price even when refunded" do
        create(:refund, purchase:, amount_cents: 100).update_column(:created_at, cutover.beginning_of_day + 5.days)
        purchase.update!(stripe_refunded: true)

        # Post-cutover purchases report gross; their refund rows (in the refund's own
        # period) are what offset them.
        expect(purchase.price_cents_for_tax_reporting).to eq(100)
      end
    end

    context "when the purchase is chargedback and not reversed" do
      let(:purchase) do
        create(:purchase, link: product).tap { |p| p.update_column(:created_at, cutover.beginning_of_day + 1.day) }
      end

      it "returns 0 (chargeback attribution is unchanged by the refund cutover)" do
        purchase.update!(chargeback_date: Time.current)

        expect(purchase.price_cents_for_tax_reporting).to eq(0)
      end
    end
  end
end

describe "Refund.for_tax_period_reporting" do
  let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }
  let(:purchase) do
    create(:purchase).tap { |p| p.update_column(:created_at, cutover.beginning_of_day - 30.days) }
  end

  it "includes only post-cutover refunds inside the window, excluding terminal-failure refunds" do
    pre_cutover = create(:refund, purchase:, amount_cents: 10).tap { |r| r.update_column(:created_at, cutover.beginning_of_day - 1.day) }
    in_window = create(:refund, purchase:, amount_cents: 10).tap { |r| r.update_column(:created_at, cutover.beginning_of_day + 1.day) }
    failed = create(:refund, purchase:, amount_cents: 10, status: "failed").tap { |r| r.update_column(:created_at, cutover.beginning_of_day + 2.days) }
    after_window = create(:refund, purchase:, amount_cents: 10).tap { |r| r.update_column(:created_at, cutover.beginning_of_day + 40.days) }

    result = Refund.for_tax_period_reporting(cutover.beginning_of_day, cutover.beginning_of_day + 30.days)

    expect(result).to include(in_window)
    expect(result).not_to include(pre_cutover, failed, after_window)
  end
end
