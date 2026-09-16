# frozen_string_literal: true

require "spec_helper"

describe Purchase::Risk do
  describe "chargeback payment grace" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:merchant_account) { create(:merchant_account, user: seller) }
    let(:charge) { create(:charge, seller:, merchant_account:) }

    def old_purchase(charge: nil, **attributes)
      purchase = create(:purchase, link: product, email: "buyer@example.com", browser_guid: "buyer-guid",
                                   chargeback_date: 2.years.ago, merchant_account:,
                                   stripe_transaction_id: charge&.processor_transaction_id || "legacy-transaction",
                                   **attributes)
      charge.purchases << purchase if charge
      purchase
    end

    def check_chargebacks
      purchase = build(:purchase, link: product, email: "buyer@example.com", browser_guid: "buyer-guid")
      purchase.send(:check_for_past_chargebacks)
      purchase.error_code
    end

    it "counts ordinary cart items on one canonical Charge once" do
      2.times { old_purchase(charge:) }
      create(:dispute_on_charge, charge:, state: :lost, charge_processor_id: "stripe", charge_processor_dispute_id: "dp_cart")

      expect(check_chargebacks).to be_nil
    end

    it "uses the canonical Charge when purchase transaction fields are missing" do
      2.times { old_purchase(charge:).update_column(:stripe_transaction_id, nil) }

      expect(check_chargebacks).to be_nil
    end

    it "accepts a charge-linked dispute when the purchase processor is missing" do
      2.times { old_purchase(charge:).update_column(:charge_processor_id, nil) }
      create(:dispute_on_charge, charge:, charge_processor_id: "stripe", charge_processor_dispute_id: "dp_cart")

      expect(check_chargebacks).to be_nil
    end

    it "does not alias a legacy row to a canonical Charge based on its transaction alone" do
      old_purchase(charge:)
      old_purchase(stripe_transaction_id: charge.processor_transaction_id)

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "keeps independent charges in one order separate" do
      old_purchase(charge:)
      other_charge = create(:charge, order: charge.order, seller:, merchant_account:)
      old_purchase(charge: other_charge)

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "keeps different sellers' charges separate within one order" do
      old_purchase(charge:)
      other_seller = create(:user)
      other_charge = create(:charge, order: charge.order, seller: other_seller)
      old_purchase(charge: other_charge, link: create(:product, user: other_seller), merchant_account: other_charge.merchant_account)

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "normalizes a bundle child without payment identifiers before counting cart items" do
      bundle = create(:product, :bundle, user: seller)
      parent = old_purchase(charge:, link: bundle, is_bundle_purchase: true)
      Purchase::CreateBundleProductPurchaseService.new(parent, bundle.bundle_products.first).perform
      child = parent.product_purchases.first
      child.update!(chargeback_date: parent.chargeback_date, stripe_transaction_id: nil, merchant_account: nil, charge_processor_id: nil)
      old_purchase(charge:)

      expect(check_chargebacks).to be_nil
    end

    it "checks the age of a GUID-only bundle child even when the email-matched parent is old" do
      bundle = create(:product, :bundle, user: seller)
      parent = old_purchase(link: bundle, is_bundle_purchase: true, browser_guid: "other-guid")
      Purchase::CreateBundleProductPurchaseService.new(parent, bundle.bundle_products.first).perform
      parent.product_purchases.first.update!(email: "other@example.com", browser_guid: "buyer-guid", chargeback_date: 1.month.ago)

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "checks every row when old email and recent GUID matches share a Charge" do
      old_purchase(charge:, browser_guid: "other-guid")
      old_purchase(charge:, email: "other@example.com", chargeback_date: 1.month.ago)

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "requires a chargeback date strictly before the one-year cutoff" do
      travel_to(Time.current.change(usec: 0)) do
        purchase = old_purchase(chargeback_date: 1.year.ago)
        expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
        purchase.update!(chargeback_date: 1.year.ago - 1.second)
        expect(check_chargebacks).to be_nil
      end
    end

    %w[stripe braintree].each do |processor|
      context "with legacy #{processor} payments" do
        let(:merchant_account) { create(:merchant_account, user: seller, charge_processor_id: processor) }

        it "counts a shared nonblank transaction in the same processor account once without a Dispute" do
          2.times { old_purchase(charge_processor_id: processor) }

          expect(check_chargebacks).to be_nil
        end

        it "keeps different transactions separate" do
          old_purchase(charge_processor_id: processor)
          old_purchase(charge_processor_id: processor, stripe_transaction_id: "other-transaction")

          expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
        end
      end
    end

    it "scopes identical transaction and dispute IDs to their processor" do
      stripe_purchase = old_purchase
      braintree_account = create(:merchant_account, user: seller, charge_processor_id: "braintree")
      braintree_purchase = old_purchase(charge_processor_id: "braintree", merchant_account: braintree_account)
      [stripe_purchase, braintree_purchase].each do |purchase|
        create(:dispute, purchase:, charge_processor_id: purchase.charge_processor_id, charge_processor_dispute_id: "same-case")
      end

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "scopes identical transaction and dispute IDs to their merchant account" do
      first = old_purchase
      second = old_purchase(merchant_account: create(:merchant_account, user: seller))
      [first, second].each { create(:dispute, purchase: _1, charge_processor_id: "stripe", charge_processor_dispute_id: "same-case") }

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    [nil, "", " "].each do |transaction_id|
      it "does not collapse legacy purchases with transaction ID #{transaction_id.inspect}" do
        2.times { old_purchase.update_column(:stripe_transaction_id, transaction_id) }

        expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
      end
    end

    [nil, ""].each do |processor|
      it "does not collapse legacy purchases with processor #{processor.inspect}" do
        2.times { old_purchase.update_column(:charge_processor_id, processor) }

        expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
      end
    end

    it "does not collapse legacy transactions without an account" do
      2.times { old_purchase.update_column(:merchant_account_id, nil) }

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "preserves singleton grace when only the dispute records the legacy processor" do
      purchase = old_purchase
      purchase.update_column(:charge_processor_id, nil)
      create(:dispute, purchase:, charge_processor_id: "stripe", charge_processor_dispute_id: "dp_legacy")

      expect(check_chargebacks).to be_nil
    end

    it "preserves singleton grace without merging contradictory legacy identifiers" do
      create(:dispute, purchase: old_purchase, charge_processor_id: "braintree", charge_processor_dispute_id: "dp_legacy")

      expect(check_chargebacks).to be_nil
    end

    it "does not trust a dangling merchant account ID" do
      2.times { old_purchase.update_column(:merchant_account_id, merchant_account.id + 100) }

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "does not trust a merchant account from a different processor" do
      2.times { old_purchase(charge_processor_id: "braintree") }

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    [:stripe_transaction_id, :charge_processor_id, :merchant_account_id, :seller_id].each do |attribute|
      it "does not trust a canonical Charge that contradicts the purchase #{attribute}" do
        old_purchase(charge:)
        purchase = old_purchase(charge:)
        value = [:merchant_account_id, :seller_id].include?(attribute) ? 0 : "contradiction"
        purchase.update_column(attribute, value)

        expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
      end
    end

    it "does not trust an incomplete canonical Charge" do
      2.times { old_purchase(charge:) }
      charge.update!(processor_transaction_id: nil)

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "does not fall back to transaction IDs when a referenced Charge is missing" do
      2.times do
        purchase = old_purchase
        charge.purchases << purchase
        purchase.reload.charge_purchase.update_column(:charge_id, charge.id + 100)
      end

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "rejects conflicting purchase-linked dispute IDs on one legacy transaction" do
      %w[case-one case-two].each do |case_id|
        create(:dispute, purchase: old_purchase, charge_processor_id: "stripe", charge_processor_dispute_id: case_id)
      end

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "rejects conflicting purchase-linked and charge-linked dispute IDs" do
      purchase = old_purchase(charge:)
      old_purchase(charge:)
      create(:dispute, purchase:, charge_processor_id: "stripe", charge_processor_dispute_id: "case-one")
      create(:dispute_on_charge, charge:, charge_processor_id: "stripe", charge_processor_dispute_id: "case-two")

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "does not split one transaction when only one purchase has a dispute ID" do
      create(:dispute, purchase: old_purchase, charge_processor_id: "stripe", charge_processor_dispute_id: "case-one")
      old_purchase

      expect(check_chargebacks).to be_nil
    end

    it "rejects a contradictory dispute processor" do
      create(:dispute, purchase: old_purchase, charge_processor_id: "braintree", charge_processor_dispute_id: "case-one")
      old_purchase

      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "excludes reversed rows without hiding an unreversed recent sibling" do
      old_purchase(charge:, chargeback_date: Time.current, chargeback_reversed: true)
      remaining = old_purchase(charge:)
      expect(check_chargebacks).to be_nil

      remaining.update!(chargeback_date: Time.current)
      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "counts a won-to-lost payment again when its reversal is cleared" do
      purchases = Array.new(2) { old_purchase(charge:, chargeback_reversed: true, chargeback_date: Time.current) }
      dispute = create(:dispute_on_charge, charge:, state: :won, charge_processor_id: "stripe", charge_processor_dispute_id: "dp_reopened")
      expect(check_chargebacks).to be_nil

      dispute.mark_lost!
      purchases.each { _1.update!(chargeback_reversed: false) }
      expect(check_chargebacks).to eq(PurchaseErrorCode::BUYER_CHARGED_BACK)
    end

    it "keeps PayPal excluded while counting an old card cart" do
      2.times { old_purchase(charge:) }
      old_purchase(charge_processor_id: "paypal", chargeback_date: Time.current)

      expect(check_chargebacks).to be_nil
    end

    it "leaves stored chargebacks and dispute states unchanged when granting grace" do
      purchases = Array.new(2) { old_purchase(charge:) }
      dispute = create(:dispute_on_charge, charge:, state: :lost)
      expect { check_chargebacks }.not_to change { purchases.map { _1.reload.attributes } + [dispute.reload.attributes, charge.reload.attributes] }
    end

    [:cart, :bundle, :missing_identity].each do |kind|
      it "bounds query growth for #{kind} history" do
        add_payment = lambda do
          if kind == :bundle
            bundle = create(:product, :bundle, user: seller)
            parent = old_purchase(charge:, link: bundle, is_bundle_purchase: true)
            Purchase::CreateBundleProductPurchaseService.new(parent, bundle.bundle_products.first).perform
            parent.product_purchases.first.update!(chargeback_date: parent.chargeback_date)
          else
            purchase = old_purchase(charge: kind == :cart ? charge : nil)
            purchase.update_column(:merchant_account_id, nil) if kind == :missing_identity
          end
        end
        count_queries = lambda do
          purchase = build(:purchase, link: product, email: "buyer@example.com", browser_guid: "buyer-guid")
          queries = []
          subscriber = ->(*args) { queries << args.last[:sql] unless args.last[:name] == "SCHEMA" }
          ActiveRecord::Base.uncached do
            ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { purchase.send(:check_for_past_chargebacks) }
          end
          queries.count { _1.match?(/\ASELECT/i) }
        end

        2.times { add_payment.call }
        small_count = count_queries.call
        8.times { add_payment.call }
        large_count = count_queries.call

        RSpec.configuration.reporter.message("#{kind} SELECT queries for 2 -> 10 payments: #{small_count} -> #{large_count}")
        expect(large_count).to be <= small_count + 1
        expect(large_count).to be <= 12
      end
    end
  end
end
