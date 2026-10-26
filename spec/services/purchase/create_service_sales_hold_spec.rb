# frozen_string_literal: true

require "spec_helper"

describe Purchase::CreateService, "for a listing on a sales hold" do
  let(:admin) { create(:admin_user) }
  let(:seller) { create(:user) }
  let(:paid_product) { create(:product, user: seller, price_cents: 6_00) }
  let(:free_product) { create(:product, user: seller, price_cents: 0) }

  def checkout(product, email: "buyer@example.com", reload: true)
    product.reload if reload
    params = {
      purchase: {
        email:,
        quantity: 1,
        perceived_price_cents: product.price_cents,
        ip_address: "0.0.0.0",
        session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
        is_mobile: false,
        browser_guid: SecureRandom.uuid
      }
    }
    if product.is_bundle?
      params[:bundle_products] = product.bundle_products.alive.map do |bundle_product|
        { product_id: bundle_product.product.external_id, variant_id: nil, quantity: bundle_product.quantity }
      end
    end
    Purchase::CreateService.new(product:, params:).perform
  end

  def successful_sales_of(product)
    Purchase.where(link_id: product.id).successful
  end

  # Stops a paid checkout where it would load the card, so neither side reaches the payment processor.
  def stop_paid_checkouts_at_the_card_step(charge_attempts)
    allow_any_instance_of(Purchase).to receive(:load_chargeable_for_charging) do |purchase|
      charge_attempts << purchase.link_id
      purchase.errors.add(:base, "Stopped before charging")
      nil
    end
  end

  describe "a paid checkout" do
    let(:charge_attempts) { [] }

    before { stop_paid_checkouts_at_the_card_step(charge_attempts) }

    it "reaches the card step when the listing is not held" do
      purchase, error = checkout(paid_product)

      expect(error).to eq("Stopped before charging")
      expect(purchase.error_code).not_to eq(PurchaseErrorCode::NOT_FOR_SALE)
      expect(charge_attempts).to eq([paid_product.id])
    end

    it "is refused before the card step while the listing is held" do
      paid_product.hold_sales!(seller:, held_by: admin)

      purchase, error = checkout(paid_product)

      expect(error).to eq("This product is not currently for sale.")
      expect(purchase.error_code).to eq(PurchaseErrorCode::NOT_FOR_SALE)
      expect(purchase).to be_failed
      expect(charge_attempts).to be_empty
    end
  end

  describe "a free checkout" do
    it "succeeds when the listing is not held" do
      purchase, error = checkout(free_product)

      expect(error).to be_nil
      expect(purchase).to be_successful
    end

    it "is refused while the listing is held" do
      free_product.hold_sales!(seller:, held_by: admin)

      purchase, error = checkout(free_product)

      expect(error).to eq("This product is not currently for sale.")
      expect(purchase).to be_failed
      expect(free_product.sales.successful).to be_empty
    end

    it "succeeds again once the hold is released and the seller republishes" do
      hold, = free_product.hold_sales!(seller:, held_by: admin)
      free_product.reload.release_sales_hold!(hold, seller:, released_by: admin)
      free_product.reload.publish!

      purchase, error = checkout(free_product)

      expect(error).to be_nil
      expect(purchase).to be_successful
    end
  end

  describe "a bundle that includes the listing" do
    let(:other_listing) { create(:product, user: seller) }
    let(:free_bundle) { create(:product, :bundle, user: seller, price_cents: 0) }
    let(:held_member) { free_bundle.bundle_products.first.product }

    it "delivers every member when no member is held" do
      purchase, error = checkout(free_bundle)

      expect(error).to be_nil
      expect(purchase).to be_successful
      expect(purchase.product_purchases.map(&:link)).to match_array(free_bundle.bundle_products.map(&:product))
      expect(successful_sales_of(held_member).count).to eq(1)
    end

    it "refuses the whole checkout and grants no member while one member is held" do
      held_member.hold_sales!(seller:, held_by: admin)

      purchase, error = checkout(free_bundle)

      expect(error).to eq("#{held_member.name} is not currently for sale.")
      expect(purchase.error_code).to eq(PurchaseErrorCode::NOT_FOR_SALE)
      expect(purchase).not_to be_successful
      expect(successful_sales_of(free_bundle)).to be_empty
      expect(successful_sales_of(held_member)).to be_empty
      expect(BundleProductPurchase.count).to eq(0)
    end

    it "refuses a bundle the seller builds around a listing that is already held" do
      held_listing = create(:product, user: seller, name: "Already held")
      held_listing.hold_sales!(seller:, held_by: admin)
      new_bundle = create(:product, user: seller, price_cents: 0, is_bundle: true, native_type: Link::NATIVE_TYPE_BUNDLE)
      Bundle::UpdateProductsService.new(
        bundle: new_bundle,
        products: [{ product_id: held_listing.external_id, variant_id: nil, quantity: 1 }, { product_id: other_listing.external_id, variant_id: nil, quantity: 1 }]
      ).perform

      purchase, error = checkout(new_bundle)

      expect(error).to eq("Already held is not currently for sale.")
      expect(purchase).not_to be_successful
      expect(successful_sales_of(held_listing)).to be_empty
    end

    it "sells the bundle again once the hold is released" do
      hold, = held_member.hold_sales!(seller:, held_by: admin)
      held_member.reload.release_sales_hold!(hold, seller:, released_by: admin)

      purchase, error = checkout(free_bundle)

      expect(error).to be_nil
      expect(purchase).to be_successful
      expect(successful_sales_of(held_member).count).to eq(1)
    end

    describe "hold lookups" do
      def bundle_of(size)
        bundle = create(:product, user: seller, price_cents: 0, is_bundle: true, native_type: Link::NATIVE_TYPE_BUNDLE)
        members = Array.new(size) { |i| create(:product, user: seller, name: "Member #{i + 1}") }
        Bundle::UpdateProductsService.new(bundle:, products: members.map { { product_id: _1.external_id, variant_id: nil, quantity: 1 } }).perform
        [bundle, members]
      end

      # Every statement that touches the holds table, including query-cache hits.
      def hold_reads(&block)
        reads = []
        callback = ->(*, payload) { reads << payload if payload[:sql].include?("product_sales_holds") }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
        reads
      end

      it "reads holds once per checkout however many members the bundle has" do
        small, = bundle_of(2)
        large, = bundle_of(6)

        results = {}
        reads = { 2 => hold_reads { results[2] = checkout(small) }, 6 => hold_reads { results[6] = checkout(large) } }

        expect(reads.transform_values(&:size)).to eq(2 => 1, 6 => 1)
        expect(results.values.map(&:last)).to eq([nil, nil])
        expect(results.values.map(&:first)).to all(be_successful)
      end

      it "names the first held member and grants nothing when several members are held" do
        bundle, members = bundle_of(6)
        [members[2], members[4]].each { _1.hold_sales!(seller:, held_by: admin) }

        purchase = error = nil
        reads = hold_reads { purchase, error = checkout(bundle) }

        expect(reads.size).to eq(1)
        expect(error).to eq("Member 3 is not currently for sale.")
        expect(purchase.error_code).to eq(PurchaseErrorCode::NOT_FOR_SALE)
        expect(Purchase.where(link_id: [bundle.id, *members.map(&:id)]).successful).to be_empty
        expect(BundleProductPurchase.count).to eq(0)
      end

      it "reads the current hold state on every checkout" do
        bundle, members = bundle_of(3)
        hold, = members[1].hold_sales!(seller:, held_by: admin)

        outcomes = []
        reads = hold_reads { 2.times { outcomes << checkout(bundle).last } }
        expect(outcomes).to eq(["Member 2 is not currently for sale."] * 2)
        expect(reads.size).to eq(2)

        members[1].reload.release_sales_hold!(hold, seller:, released_by: admin)
        purchase, error = checkout(bundle)
        expect(error).to be_nil
        expect(purchase).to be_successful
      end

      it "reads holds from the database even when the request's query cache holds the same statement" do
        bundle, members = bundle_of(3)
        members[1].hold_sales!(seller:, held_by: admin)

        outcome = nil
        # `reload` clears the query cache, so the bundle is reloaded before priming and not again.
        reads = ActiveRecord::Base.cache do
          bundle.reload
          ProductSalesHold.active.where(product_id: bundle.bundle_products.alive.map(&:product_id)).distinct.pluck(:product_id)
          hold_reads { outcome = checkout(bundle, reload: false) }
        end

        expect(outcome.last).to eq("Member 2 is not currently for sale.")
        expect(reads.size).to eq(1)
        expect(reads.first[:cached]).to be_falsey
      end
    end

    describe "when paid" do
      let(:paid_bundle) { create(:product, :bundle, user: seller, price_cents: 10_00) }
      let(:charge_attempts) { [] }

      before { stop_paid_checkouts_at_the_card_step(charge_attempts) }

      it "reaches the card step when no member is held" do
        _purchase, error = checkout(paid_bundle)

        expect(error).to eq("Stopped before charging")
        expect(charge_attempts).to eq([paid_bundle.id])
      end

      it "is refused before the card step while a member is held" do
        member = paid_bundle.bundle_products.first.product
        member.hold_sales!(seller:, held_by: admin)

        purchase, error = checkout(paid_bundle)

        expect(error).to eq("#{member.name} is not currently for sale.")
        expect(purchase.error_code).to eq(PurchaseErrorCode::NOT_FOR_SALE)
        expect(charge_attempts).to be_empty
        expect(purchase.charge_intent).to be_nil
        expect(successful_sales_of(member)).to be_empty
      end
    end
  end
end
