# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillBundleRefundReviews do
  before do
    allow(ReplicaLagWatcher).to receive(:watch)
  end

  describe "#process" do
    context "when bundle was fully refunded before PR #2460" do
      let!(:bundle_purchase) do
        purchase = create(:purchase, link: create(:product, :bundle), created_at: Date.new(2025, 6, 1))
        purchase.create_artifacts_and_send_receipt!
        purchase.update_columns(stripe_refunded: true)
        purchase
      end

      it "sets stripe_refunded on product purchases and soft-deletes reviews" do
        bundle_purchase.product_purchases.each do |pp|
          pp.post_review(rating: 1, message: "bad")
          expect(pp.product_review).to be_alive
        end

        described_class.new(dry_run: false).process

        bundle_purchase.product_purchases.each do |pp|
          pp.reload
          expect(pp.stripe_refunded).to eq(true)
          expect(pp.product_review.reload).to be_deleted
          expect(pp.link.reviews_count).to eq(0)
        end
      end
    end

    context "when bundle was partially refunded before PR #2460" do
      let!(:bundle_purchase) do
        purchase = create(:purchase, link: create(:product, :bundle), created_at: Date.new(2025, 6, 1))
        purchase.create_artifacts_and_send_receipt!
        purchase.update_columns(stripe_partially_refunded: true)
        purchase
      end

      it "sets stripe_partially_refunded on product purchases and soft-deletes reviews" do
        bundle_purchase.product_purchases.each do |pp|
          pp.post_review(rating: 2, message: "meh")
          expect(pp.product_review).to be_alive
        end

        described_class.new(dry_run: false).process

        bundle_purchase.product_purchases.each do |pp|
          pp.reload
          expect(pp.stripe_partially_refunded).to eq(true)
          expect(pp.product_review.reload).to be_deleted
          expect(pp.link.reviews_count).to eq(0)
        end
      end
    end

    context "when product purchases already have the refund flag but reviews were not removed" do
      let!(:bundle_purchase) do
        purchase = create(:purchase, link: create(:product, :bundle), created_at: Date.new(2026, 2, 1))
        purchase.create_artifacts_and_send_receipt!
        purchase.update_columns(stripe_partially_refunded: true)
        purchase
      end

      it "explicitly repairs reviews and updates stats" do
        bundle_purchase.product_purchases.each do |pp|
          pp.post_review(rating: 3, message: "ok")
          expect(pp.product_review).to be_alive
          expect(pp.link.reviews_count).to eq(1)
          pp.update_columns(stripe_partially_refunded: true)
        end

        described_class.new(dry_run: false).process

        bundle_purchase.product_purchases.each do |pp|
          pp.reload
          expect(pp.stripe_partially_refunded).to eq(true)
          expect(pp.product_review.reload).to be_deleted
          expect(pp.link.reviews_count).to eq(0)
        end
      end
    end

    context "when product purchase is already refunded and review is already deleted" do
      let!(:bundle_purchase) do
        purchase = create(:purchase, link: create(:product, :bundle), created_at: Date.new(2025, 6, 1))
        purchase.create_artifacts_and_send_receipt!
        purchase.update_columns(stripe_refunded: true)
        purchase
      end

      it "skips already-repaired product purchases" do
        bundle_purchase.product_purchases.each do |pp|
          pp.post_review(rating: 1, message: "bad")
          pp.update_columns(stripe_refunded: true)
          pp.product_review.mark_deleted!
        end

        described_class.new(dry_run: false).process

        bundle_purchase.product_purchases.each do |pp|
          expect(pp.reload.stripe_refunded).to eq(true)
          expect(pp.product_review.reload).to be_deleted
        end
      end
    end

    context "when product purchase has no review" do
      let!(:bundle_purchase) do
        purchase = create(:purchase, link: create(:product, :bundle), created_at: Date.new(2025, 6, 1))
        purchase.create_artifacts_and_send_receipt!
        purchase.update_columns(stripe_refunded: true)
        purchase
      end

      it "sets the refund flag without error" do
        expect { described_class.new(dry_run: false).process }.not_to raise_error

        bundle_purchase.product_purchases.each do |pp|
          expect(pp.reload.stripe_refunded).to eq(true)
        end
      end
    end

    context "with dry_run: true" do
      let!(:bundle_purchase) do
        purchase = create(:purchase, link: create(:product, :bundle), created_at: Date.new(2025, 6, 1))
        purchase.create_artifacts_and_send_receipt!
        purchase.update_columns(stripe_refunded: true)
        purchase
      end

      it "logs but does not modify data" do
        bundle_purchase.product_purchases.each do |pp|
          pp.post_review(rating: 1, message: "bad")
        end

        expect(Rails.logger).to receive(:info).with(/\[DRY RUN\]/).at_least(:once)

        described_class.new(dry_run: true).process

        bundle_purchase.product_purchases.each do |pp|
          expect(pp.reload.stripe_refunded).to be_nil
          expect(pp.product_review.reload).to be_alive
        end
      end
    end
  end
end
