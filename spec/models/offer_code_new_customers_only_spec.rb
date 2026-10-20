# frozen_string_literal: true

require "spec_helper"

describe OfferCode, "limited to new customers" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 2000) }
  let(:other_product) { create(:product, user: seller, price_cents: 1000) }
  let(:offer_code) { create(:offer_code, :for_new_customers, user: seller, products: [product], code: "first10") }

  describe "validations" do
    it "persists the flag without touching the existing-customer setting" do
      expect(offer_code.reload.new_customers_only?).to eq(true)
      expect(offer_code.existing_customers_only?).to eq(false)
    end

    it "rejects automatic application" do
      code = build(:universal_offer_code, :for_new_customers, user: seller, auto_apply: true, amount_cents: nil, amount_percentage: 10, currency_type: nil)

      expect(code).not_to be_valid
      expect(code.errors.full_messages).to include("A discount limited to new customers cannot be applied automatically.")
    end

    it "rejects limiting a product's default discount to new customers, naming the product setting to turn off" do
      product.update!(name: "Pro Course")
      code = create(:offer_code, user: seller, products: [product], code: "launch")
      product.update!(default_offer_code: code)

      code.new_customers_only = true

      expect(code).not_to be_valid
      expect(code.errors.full_messages).to include("This code is applied automatically on “Pro Course”. Turn off “Automatically apply discount code” in that product’s editor (under Pricing, or Tiers for memberships), then try again.")
    end

    it "names a bounded list of the products that apply the code automatically" do
      code = create(:universal_offer_code, user: seller, code: "launch", amount_cents: nil, amount_percentage: 10, currency_type: nil)
      %w[Alpha Bravo Charlie Delta].each { create(:product, user: seller, name: _1, price_cents: 1000, default_offer_code: code) }

      code.new_customers_only = true

      expect(code).not_to be_valid
      expect(code.errors.full_messages).to include("This code is applied automatically on “Alpha”, “Bravo”, “Charlie”, and 1 other. Turn off “Automatically apply discount code” in those products’ editors (under Pricing, or Tiers for memberships), then try again.")
    end

    it "allows unrelated edits of a code that is already limited to new customers" do
      offer_code.update!(max_purchase_count: 5)

      expect(offer_code.reload.max_purchase_count).to eq(5)
    end
  end

  describe "#returning_customer?" do
    let(:buyer) { create(:user, email: "returning.buyer@example.com") }

    it "is false for a buyer with no purchases from the seller" do
      expect(offer_code.returning_customer?(purchaser_ids: [buyer.id], emails: [buyer.email])).to eq(false)
    end

    it "matches an account's purchase of any product in the seller's store" do
      create(:purchase, link: other_product, purchaser: buyer, email: "different@example.com")

      expect(offer_code.returning_customer?(purchaser_ids: [buyer.id], emails: [])).to eq(true)
    end

    it "matches a guest purchase by email regardless of case" do
      create(:purchase, link: other_product, purchaser: nil, email: "Returning.Buyer@Example.com")

      expect(offer_code.returning_customer?(emails: ["returning.buyer@EXAMPLE.COM"])).to eq(true)
    end

    it "ignores purchases from other sellers" do
      create(:purchase, link: create(:product), purchaser: buyer, email: buyer.email)

      expect(offer_code.returning_customer?(purchaser_ids: [buyer.id], emails: [buyer.email])).to eq(false)
    end

    it "ignores the purchase being checked" do
      purchase = create(:purchase, link: product, purchaser: buyer, email: buyer.email)

      expect(offer_code.returning_customer?(purchaser_ids: [buyer.id], emails: [buyer.email], excluding_purchase: purchase)).to eq(false)
    end

    it "ignores purchases that do not count as owning a product" do
      create(:failed_purchase, link: other_product, purchaser: buyer, email: buyer.email)
      create(:purchase_in_progress, link: other_product, purchaser: buyer, email: buyer.email)
      create(:purchase, link: other_product, purchaser: buyer, email: buyer.email, stripe_refunded: true)
      create(:purchase, link: other_product, purchaser: buyer, email: buyer.email, chargeback_date: Time.current)
      create(:purchase, link: other_product, purchaser: buyer, email: buyer.email, is_gift_sender_purchase: true)
      create(:purchase, link: other_product, purchaser: buyer, email: buyer.email, is_access_revoked: true)
      create(:purchase, link: other_product, purchaser: buyer, email: buyer.email, is_additional_contribution: true)

      expect(offer_code.returning_customer?(purchaser_ids: [buyer.id], emails: [buyer.email])).to eq(false)
    end

    it "counts a purchase whose chargeback was reversed" do
      create(:purchase, link: other_product, purchaser: buyer, email: buyer.email, chargeback_date: Time.current, chargeback_reversed: true)

      expect(offer_code.returning_customer?(purchaser_ids: [buyer.id], emails: [buyer.email])).to eq(true)
    end
  end

  describe "as a product default" do
    let(:default_code) { create(:offer_code, user: seller, products: [product], code: "launch") }

    before { product.update!(default_offer_code: default_code) }

    it "clears the default when the code was limited to new customers while the product was deleted" do
      product.update!(deleted_at: Time.current)
      default_code.update!(new_customers_only: true)

      product.update!(deleted_at: nil)

      expect(product.reload.default_offer_code_id).to be_nil
    end

    it "clears a default assigned concurrently with the edit that limited the code to new customers" do
      # This edit's validation read the defaults before the concurrent assignment landed.
      allow_any_instance_of(OfferCode).to receive(:validate_new_customer_settings)

      default_code.update!(new_customers_only: true)

      expect(product.reload.default_offer_code_id).to be_nil
    end

    it "clears an assignment that committed after the code was limited to new customers" do
      other_code = create(:offer_code, :for_new_customers, user: seller, products: [product], code: "welcome")
      # The assignment's validation read the code before the concurrent change landed.
      allow_any_instance_of(Link).to receive(:default_offer_code_must_be_valid)

      product.update!(default_offer_code: other_code)

      expect(product.reload.default_offer_code_id).to be_nil
    end

    it "is detached by both the SQL scope and the Ruby predicate" do
      default_code.update_column(:new_customers_only, true)
      product.reload

      expect(Link.where(id: product.id).with_detached_default_offer_code.exists?).to eq(true)
      expect(product.default_offer_code_detached?).to eq(true)
    end

    it "never prices the product with a new-customer default that is still attached" do
      default_code.update_column(:new_customers_only, true)
      sale = create(:universal_offer_code, user: seller, auto_apply: true, amount_cents: nil, amount_percentage: 10, currency_type: nil, code: "shopsale")

      expect(product.reload.effective_default_offer_code).to eq(sale)

      sale.update!(auto_apply: false)
      expect(product.reload.effective_default_offer_code).to be_nil
    end
  end
end
