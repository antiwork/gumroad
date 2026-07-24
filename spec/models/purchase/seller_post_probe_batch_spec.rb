# frozen_string_literal: true

require "spec_helper"

describe Purchase::SellerPostProbeBatch do
  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @purchase = create(:free_purchase, link: @product, seller: @seller)
  end

  def batch_for(purchases)
    described_class.new(purchases)
  end

  describe "#covers?" do
    it "covers the batch purchases' exact emails for the batch's sellers" do
      batch = batch_for([@purchase])

      expect(batch.covers?(seller_id: @seller.id, email: @purchase.email)).to eq(true)
      # Coverage is exact-string on purpose: probe emails come from the same
      # purchase objects the batch was built from, and anything else (like a
      # differently-cased string) falls back to the SQL probe rather than
      # re-implementing the database collation's equality rules in Ruby.
      expect(batch.covers?(seller_id: @seller.id, email: @purchase.email.upcase)).to eq(false)
    end

    it "does not cover other emails or nil" do
      batch = batch_for([@purchase])

      expect(batch.covers?(seller_id: @seller.id, email: "someone-else@example.com")).to eq(false)
      expect(batch.covers?(seller_id: @seller.id, email: nil)).to eq(false)
      expect(batch.covers?(seller_id: @seller.id, email: "")).to eq(false)
    end

    it "does not cover sellers outside the batch, even for a covered email" do
      other_seller = create(:user)
      batch = batch_for([@purchase])

      expect(batch.covers?(seller_id: other_seller.id, email: @purchase.email)).to eq(false)
    end
  end

  describe "#matched?" do
    it "matches when the buyer bought an excluded product from the seller" do
      batch = batch_for([@purchase])

      expect(batch.matched?(
        seller_id: @seller.id,
        email: @purchase.email,
        not_bought_variant_external_ids: [],
        exclude_product_ids: [@product.id]
      )).to eq(true)
    end

    it "does not match when the buyer only bought other products from the seller" do
      other_product = create(:product, user: @seller)
      batch = batch_for([@purchase])

      expect(batch.matched?(
        seller_id: @seller.id,
        email: @purchase.email,
        not_bought_variant_external_ids: [],
        exclude_product_ids: [other_product.id]
      )).to eq(false)
    end

    it "does not match against a different seller's sales" do
      # Both sellers are IN the batch (each contributed a purchase), so this
      # exercises seller isolation within a covered batch — probing seller B
      # for a product only ever bought from seller A must not match.
      other_seller = create(:user)
      other_purchase = create(:free_purchase, link: create(:product, user: other_seller), seller: other_seller, email: @purchase.email)
      batch = batch_for([@purchase, other_purchase])

      expect(batch.matched?(
        seller_id: other_seller.id,
        email: @purchase.email,
        not_bought_variant_external_ids: [],
        exclude_product_ids: [@product.id]
      )).to eq(false)
    end

    it "matches when the buyer bought an excluded variant" do
      variant = create(:variant, variant_category: create(:variant_category, link: @product))
      @purchase.variant_attributes << variant
      batch = batch_for([@purchase])

      expect(batch.matched?(
        seller_id: @seller.id,
        email: @purchase.email,
        not_bought_variant_external_ids: [variant.external_id],
        exclude_product_ids: []
      )).to eq(true)
    end

    it "matches by product when variant ids are present but the purchase carries no matching variant" do
      variant = create(:variant, variant_category: create(:variant_category, link: create(:product, user: @seller)))
      batch = batch_for([@purchase])

      # Mirrors the SQL UNION in Purchase::Targeting#by_external_variant_ids_or_products:
      # when variant ids are given, a purchase matches by variant OR by product.
      expect(batch.matched?(
        seller_id: @seller.id,
        email: @purchase.email,
        not_bought_variant_external_ids: [variant.external_id],
        exclude_product_ids: [@product.id]
      )).to eq(true)
    end

    it "does not match when neither variant nor product intersects the buyer's purchases" do
      variant = create(:variant, variant_category: create(:variant_category, link: create(:product, user: @seller)))
      other_product = create(:product, user: @seller)
      batch = batch_for([@purchase])

      expect(batch.matched?(
        seller_id: @seller.id,
        email: @purchase.email,
        not_bought_variant_external_ids: [variant.external_id],
        exclude_product_ids: [other_product.id]
      )).to eq(false)
    end

    it "excludes archived-original-subscription and recurring-charge purchases like the SQL probe" do
      membership_product = create(:membership_product, user: @seller)
      original = create(:membership_purchase, link: membership_product, seller: @seller, email: @purchase.email)
      original.update!(is_archived_original_subscription_purchase: true)
      batch = batch_for([@purchase])

      expect(batch.matched?(
        seller_id: @seller.id,
        email: @purchase.email,
        not_bought_variant_external_ids: [],
        exclude_product_ids: [membership_product.id]
      )).to eq(false)
    end

    it "finds rows whose stored email differs in case from the batch email" do
      # The prefetch queries per batch email, so the database's
      # case-insensitive collation decides which stored rows belong to it —
      # exactly like the SQL probe's `exists?(email:)`.
      cased_purchase = create(:free_purchase, link: @product, seller: @seller, email: "Buyer@Example.com")
      probe_purchase = create(:free_purchase, link: create(:product, user: @seller), seller: @seller, email: "buyer@example.com")
      batch = batch_for([probe_purchase])

      expect(batch.matched?(
        seller_id: @seller.id,
        email: probe_purchase.email,
        not_bought_variant_external_ids: [],
        exclude_product_ids: [cased_purchase.link_id]
      )).to eq(true)
    end
  end

  describe "SQL parity with the per-seller probe" do
    def sql_probe(seller, email, not_bought_variants, exclude_product_ids)
      seller.sales
            .not_is_archived_original_subscription_purchase
            .not_subscription_or_original_purchase
            .by_external_variant_ids_or_products(not_bought_variants, exclude_product_ids)
            .exists?(email:)
    end

    it "returns the same answer as the SQL probe across sellers, products, and variants" do
      seller_b = create(:user)
      product_b = create(:product, user: seller_b)
      variant_b = create(:variant, variant_category: create(:variant_category, link: product_b))
      purchase_b = create(:free_purchase, link: product_b, seller: seller_b, email: @purchase.email)
      purchase_b.variant_attributes << variant_b

      purchases = [@purchase, purchase_b]
      batch = batch_for(purchases)

      cases = [
        [@seller, [], [@product.id]],
        [@seller, [], [product_b.id]],
        [@seller, [variant_b.external_id], []],
        [seller_b, [], [product_b.id]],
        [seller_b, [variant_b.external_id], []],
        [seller_b, [variant_b.external_id], [@product.id]],
      ]

      cases.each do |seller, not_bought_variants, exclude_product_ids|
        expect(batch.matched?(
          seller_id: seller.id,
          email: @purchase.email,
          not_bought_variant_external_ids: not_bought_variants,
          exclude_product_ids:
        )).to eq(sql_probe(seller, @purchase.email, not_bought_variants, exclude_product_ids)),
              "batch and SQL probe disagree for seller=#{seller.id} variants=#{not_bought_variants} products=#{exclude_product_ids}"
      end
    end
  end

  describe "query batching" do
    it "answers probes for many sellers without issuing per-seller queries" do
      purchases = 3.times.map do
        seller = create(:user)
        create(:free_purchase, link: create(:product, user: seller), seller: seller, email: @purchase.email)
      end
      batch = batch_for(purchases)

      # Warm the lazy prefetch, then assert subsequent probes are query-free.
      batch.matched?(
        seller_id: purchases.first.seller_id,
        email: @purchase.email,
        not_bought_variant_external_ids: [],
        exclude_product_ids: [purchases.first.link_id]
      )

      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        purchases.each do |purchase|
          expect(batch.matched?(
            seller_id: purchase.seller_id,
            email: @purchase.email,
            not_bought_variant_external_ids: [],
            exclude_product_ids: [purchase.link_id]
          )).to eq(true)
        end
      end

      expect(queries).to be_empty
    end
  end
end
