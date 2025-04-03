# frozen_string_literal: true

require "spec_helper"

describe SendBundlesMarketingEmailJob do
  describe "#perform" do
    let(:seller) { create(:user) }
    let!(:products) do
      build_list(:product, 10, user: seller) do |product, i|
        product.update!(price_cents: (i + 1) * 100, name: "Product #{i}")
      end
    end

    let!(:purchases) do
      build_list(:purchase, 10, seller:) do |purchase, i|
        product = products[i]
        purchase.update!(link: product, price_cents: product.price_cents)
      end
    end

    let(:bundles) do
      [
        {
          type: Product::BundlesMarketing::BEST_SELLING_BUNDLE,
          price: 4000,
          discounted_price: 3200,
          products: products.reverse[0..4].map { |p| { id: p.external_id, name: p.name, url: p.long_url } }
        },
        {
          type: Product::BundlesMarketing::EVERYTHING_BUNDLE,
          price: 5400,
          discounted_price: 4320,
          products: products.reverse[0..8].map { |p| { id: p.external_id, name: p.name, url: p.long_url } }
        },
        {
          type: Product::BundlesMarketing::YEAR_BUNDLE,
          price: 500,
          discounted_price: 400,
          products: products[1..2].reverse.map { |p| { id: p.external_id, name: p.name, url: p.long_url } }
        },
      ]
    end

    before do
      products[0..2].each do |product|
        product.update!(created_at: Time.current.prev_year)
      end

      create(:payment_completed, user: seller)

      index_model_records(Purchase)
      index_model_records(Link)
    end

    it "enqueues the mail with the correct arguments" do
      expect do
        described_class.new.perform
      end.to have_enqueued_mail(CreatorMailer, :bundles_marketing).with(
        seller_id: seller.id,
        bundles:,
      ).once
    end

    context "when a bundle doesn't have at least two products" do
      before do
        products[..2].each { _1.update!(created_at: Time.new(2022, 1, 1)) }
      end

      it "excludes that bundle" do
        expect do
          described_class.new.perform
        end.to have_enqueued_mail(CreatorMailer, :bundles_marketing).with(
          seller_id: seller.id,
          bundles: bundles[0..1]
        )
      end
    end

    context "no bundles" do
      before do
        products.each { _1.destroy! }
        index_model_records(Link)
      end

      it "doesn't enqueue any mail" do
        expect do
          described_class.new.perform
        end.to_not have_enqueued_mail(CreatorMailer, :bundles_marketing)
      end
    end

    context "seller is suspended" do
      before { seller.update!(user_risk_state: "suspended_for_tos_violation") }

      it "doesn't enqueue any mail" do
        expect do
          described_class.new.perform
        end.to_not have_enqueued_mail(CreatorMailer, :bundles_marketing)
      end
    end

    context "seller is deleted" do
      before { seller.update!(deleted_at: Time.current) }

      it "doesn't enqueue any mail" do
        expect do
          described_class.new.perform
        end.to_not have_enqueued_mail(CreatorMailer, :bundles_marketing)
      end
    end
  end
end
