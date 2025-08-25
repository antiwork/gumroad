# frozen_string_literal: true

require "spec_helper"

describe Charge::Chargeable do
  describe ".find_by_stripe_event" do
    describe "for an event on a Purchase" do
      it "finds the purchase using charge reference that is purchase's external id" do
        purchase = create(:purchase, id: 12345)
        event = build(:charge_event_dispute_formalized, charge_reference: purchase.external_id)
        expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(purchase)
      end

      it "finds the purchase using charge id that is purchase's stripe transaction id" do
        purchase = create(:purchase, stripe_transaction_id: "ch_12345")
        event = build(:charge_event_dispute_formalized, charge_reference: nil, charge_id: "ch_12345")
        expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(purchase)
      end

      it "finds the purchase using processor payment intent id" do
        purchase = create(:purchase)
        processor_payment_intent_id = "pi_123456"
        purchase.create_processor_payment_intent!(intent_id: processor_payment_intent_id)
        event = build(:charge_event_dispute_formalized, charge_reference: nil, charge_id: nil, processor_payment_intent_id:)
        expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(purchase)
      end
    end

    describe "for an event on a Charge" do
      it "finds the charge using charge reference that is charge's id" do
        charge = create(:charge, id: 12345)
        event = build(:charge_event_dispute_formalized, charge_reference: "CH-12345")
        expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(charge)
      end

      it "finds the charge using charge id that is charge's processor transaction id" do
        charge = create(:charge, processor_transaction_id: "ch_12345")
        event = build(:charge_event_dispute_formalized, charge_reference: "CH-12345", charge_id: "ch_12345")
        expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(charge)
      end

      it "finds the charge using processor payment intent id" do
        charge = create(:charge, stripe_payment_intent_id: "pi_123456")
        event = build(:charge_event_dispute_formalized, charge_reference: "CH-12345", charge_id: nil, processor_payment_intent_id: "pi_123456")
        expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(charge)
      end
    end
  end

  describe ".find_by_processor_transaction_id!" do
    let(:processor_transaction_id) { "ch_123456" }

    context "without a matching processor_transaction_id" do
      it "raises an error" do
        expect do
          Charge::Chargeable.find_by_processor_transaction_id!(processor_transaction_id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "with a matching processor_transaction_id for a purchase" do
      let!(:purchase) { create(:purchase, stripe_transaction_id: processor_transaction_id) }

      it "returns the purchase" do
        expect(Charge::Chargeable.find_by_processor_transaction_id!(processor_transaction_id)).to eq(purchase)
      end

      context "with a matching processor_transaction_id for a charge" do
        let!(:charge) { create(:charge, processor_transaction_id:, purchases: [purchase]) }

        it "returns the charge" do
          expect(Charge::Chargeable.find_by_processor_transaction_id!(processor_transaction_id)).to eq(charge)
        end
      end
    end
  end

  describe ".find_by_purchase_or_charge!" do
    context "when both arguments are nil" do
      it "raises an error" do
        expect do
          Charge::Chargeable.find_by_purchase_or_charge!(purchase: nil, charge: nil)
        end.to raise_error(ArgumentError).with_message("Either purchase or charge must be present")
      end
    end

    let(:purchase) { create(:purchase) }

    context "when the purchase belongs to a charge" do
      let(:charge) { create(:charge) }

      before do
        charge.purchases << purchase
      end

      context "when both arguments are present" do
        it "raises an error" do
          expect do
            Charge::Chargeable.find_by_purchase_or_charge!(purchase:, charge:)
          end.to raise_error(ArgumentError).with_message("Only one of purchase or charge must be present")
        end
      end

      context "when the charge_id is provided" do
        it "returns the purchase's charge" do
          expect(Charge::Chargeable.find_by_purchase_or_charge!(purchase:)).to eq(charge)
        end
      end
    end

    context "when the purchase does not belong to a charge" do
      it "returns the purchase" do
        expect(Charge::Chargeable.find_by_purchase_or_charge!(purchase:)).to eq(purchase)
      end
    end
  end

  describe "#support_email" do
    let(:user_level_support_email) { "user-level-support@example.com" }
    let(:product_level_support_email) { "product-level-support@example.com" }
    let(:seller) { create(:named_seller, support_email: user_level_support_email) }

    context "on a purchase" do
      let(:chargeable) { create(:purchase, link: product, seller:) }

      context "when link's support email is set" do
        let(:product) { create(:product, support_email: product_level_support_email, user: seller) }

        it "returns support_email of the link" do
          expect(chargeable.support_email).to eq(product_level_support_email)
        end
      end

      context "when link's support email is not set" do
        let(:product) { create(:product, support_email: nil, user: seller) }

        it "returns seller.support_or_form_email" do
          expect(chargeable.support_email).to eq(user_level_support_email)
        end
      end
    end

    context "on a charge" do
      context "when all purchases links have the same support email" do
        let(:chargeable) { create(:charge, purchases: [purchase1, purchase2], seller:) }
        let(:product1) { create(:product, support_email: product_level_support_email, user: seller) }
        let(:product2) { create(:product, support_email: product_level_support_email, user: seller) }
        let(:purchase1) { create(:purchase, link: product1, seller:) }
        let(:purchase2) { create(:purchase, link: product2, seller:) }

        it "returns the product level support email" do
          expect(chargeable.support_email).to eq(product_level_support_email)
        end
      end

      context "when not all purchases links have the same support email" do
        let(:chargeable) { create(:charge, purchases: [purchase1, purchase2], seller:) }
        let(:product1) { create(:product, support_email: product_level_support_email, user: seller) }
        let(:product2) { create(:product, support_email: nil, user: seller) }
        let(:purchase1) { create(:purchase, link: product1, seller:) }
        let(:purchase2) { create(:purchase, link: product2, seller:) }

        it "returns the user level support email" do
          expect(chargeable.support_email).to eq(user_level_support_email)
        end
      end
    end
  end

  describe "#charged_purchases" do
    describe "for a Charge" do
      it "returns an array containing all non-free purchases included in the Charge" do
        purchase1 = create(:purchase)
        purchase2 = create(:purchase)
        purchase3 = create(:purchase)
        free_purchase = create(:free_purchase)
        free_trial_membership_purchase = create(:free_trial_membership_purchase)

        charge = create(:charge, purchases: [purchase1, purchase2, purchase3, free_purchase, free_trial_membership_purchase])

        expect(charge.charged_purchases).to eq([purchase1, purchase2, purchase3])
      end
    end

    describe "for a Purchase" do
      it "returns a single-item array containing purchase itself" do
        purchase = create(:purchase)
        create(:purchase)
        expect(purchase.charged_purchases).to eq([purchase])
      end
    end
  end

  describe "#successful_purchases" do
    describe "for a Charge" do
      it "returns an array containing all purchases included in the Charge" do
        charge = create(:charge)
        purchase1 = create(:purchase)
        purchase2 = create(:purchase)
        purchase3 = create(:purchase, purchase_state: "failed")
        charge.purchases << purchase1
        charge.purchases << purchase2
        charge.purchases << purchase3
        expect(charge.successful_purchases).to eq([purchase1, purchase2])
      end
    end

    describe "for a Purchase" do
      it "returns the purchase itself" do
        purchase = create(:purchase)
        create(:purchase)
        expect(purchase.successful_purchases).to eq([purchase])
      end
    end
  end

  describe "#update_processor_fee_cents!", :vcr do
    describe "for a Purchase" do
      it "updates processor_fee_cents on the purchase" do
        purchase = create(:purchase, total_transaction_cents: 20_00)

        purchase.update_processor_fee_cents!(processor_fee_cents: 2_00)

        expect(purchase.processor_fee_cents).to eq 2_00
      end
    end

    describe "for a Charge" do
      it "does nothing if input processor_fee_cents is nil" do
        charge = create(:charge, amount_cents: 100_00, processor_fee_cents: nil)
        purchase = create(:purchase, total_transaction_cents: 20_00)
        charge.purchases << purchase

        expect { charge.update_processor_fee_cents!(processor_fee_cents: nil) }.not_to raise_error

        expect(charge.reload.processor_fee_cents).to be nil
        expect(purchase.reload.processor_fee_cents).to be nil
      end

      it "updates processor_fee_cents on included purchases in proper ratio" do
        charge = create(:charge, amount_cents: 100_00)
        purchase1 = create(:purchase, total_transaction_cents: 20_00)
        purchase2 = create(:purchase, total_transaction_cents: 30_00)
        purchase3 = create(:purchase, total_transaction_cents: 50_00)
        charge.purchases << purchase1
        charge.purchases << purchase2
        charge.purchases << purchase3

        charge.update_processor_fee_cents!(processor_fee_cents: 10_00)

        expect(charge.reload.processor_fee_cents).to eq 10_00
        expect(purchase1.reload.processor_fee_cents).to eq 2_00
        expect(purchase2.reload.processor_fee_cents).to eq 3_00
        expect(purchase3.reload.processor_fee_cents).to eq 5_00
      end
    end
  end

  describe "#charged_amount_cents" do
    context "then the chargeable is a charge" do
      let(:charge) { create(:charge, amount_cents: 123_00) }
      let(:purchase1) { create(:purchase, total_transaction_cents: 20_00) }
      let(:purchase2) { create(:purchase, total_transaction_cents: 30_00) }
      let(:purchase3) { create(:purchase, total_transaction_cents: 50_00, purchase_state: "failed") }

      before do
        charge.purchases << purchase1
        charge.purchases << purchase2
        charge.purchases << purchase3
      end

      it "returns the sum of successful purchases" do
        expect(charge.charged_amount_cents).to eq(50_00)
      end
    end

    it "returns the total_transaction_cents for a Purchase" do
      purchase = create(:purchase, total_transaction_cents: 3210)
      expect(purchase.charged_amount_cents).to eq(3210)
    end
  end

  describe "#charged_gumroad_amount_cents" do
    it "returns the gumroad_amount_cents for a Charge" do
      charge = create(:charge, gumroad_amount_cents: 230)
      expect(charge.charged_gumroad_amount_cents).to eq(230)
    end

    it "returns the total_transaction_amount_for_gumroad_cents for a Purchase" do
      purchase = create(:purchase, total_transaction_cents: 2000, affiliate_credit_cents: 500, fee_cents: 300)
      expect(purchase.charged_gumroad_amount_cents).to eq(purchase.total_transaction_amount_for_gumroad_cents)
    end
  end

  describe "#unbundled_purchases" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller, is_bundle: true) }
    let(:chargeable) { create(:purchase, link: product, seller:) }

    context "when is not a bundle purchase" do
      before do
        product.update!(is_bundle: false)
      end

      it "returns the same purchase" do
        expect(chargeable.unbundled_purchases).to eq([chargeable])
      end
    end

    context "when is a bundle purchase" do
      let!(:bundled_product_one) { create(:bundle_product, bundle: product, product: create(:product, user: seller)) }
      let!(:bundled_product_two) { create(:bundle_product, bundle: product, product: create(:product, user: seller)) }

      before do
        chargeable.create_artifacts_and_send_receipt!
      end

      it "returns purchases for bundled products" do
        expect(chargeable.unbundled_purchases.size).to eq(2)
        expect(chargeable.unbundled_purchases.first.link).to eq(bundled_product_one.product)
        expect(chargeable.unbundled_purchases.second.link).to eq(bundled_product_two.product)
      end
    end
  end

  describe "#is_recurring_subscription_charge" do
    context "when is a Charge" do
      let(:charge) { create(:charge) }

      it "returns false" do
        expect(charge.is_recurring_subscription_charge).to eq(false)
      end
    end

    context "when is a Purchase" do
      let(:original_membership_purchase) { create(:membership_purchase) }
      let!(:recurring_membership_purchase) do
        create(:purchase, link: original_membership_purchase.link, subscription: original_membership_purchase.subscription)
      end

      context "when the purchase is the original purchase" do
        it "returns false" do
          expect(original_membership_purchase.is_recurring_subscription_charge).to eq(false)
        end
      end

      context "when the purchase is a recurring purchase" do
        it "returns true" do
          expect(recurring_membership_purchase.is_recurring_subscription_charge).to eq(true)
        end
      end
    end
  end

  describe "#taxable?" do
    context "when is a Charge" do
      let(:charge) { create(:charge) }

      before do
        allow(charge).to receive(:taxable?).and_return("super")
      end

      it "calls super" do
        expect(charge.taxable?).to eq("super")
      end
    end

    context "when is a Purchase" do
      let(:purchase) { create(:purchase) }

      before do
        allow_any_instance_of(Purchase).to receive(:was_purchase_taxable?).and_return("super")
      end

      it "calls super" do
        expect(purchase.taxable?).to eq("super")
      end
    end
  end

  describe "#multi_item_charge?" do
    context "when is a Charge" do
      context "with one purchase" do
        let(:charge) { create(:charge, purchases: [create(:purchase)]) }

        it "returns false" do
          expect(charge.multi_item_charge?).to eq(false)
        end
      end

      context "with multiple purchases" do
        let(:charge) { create(:charge, purchases: [create(:purchase), create(:purchase)]) }

        it "returns true" do
          expect(charge.multi_item_charge?).to eq(true)
        end
      end
    end

    context "when is a Purchase" do
      let(:purchase) { create(:purchase) }

      it "returns false" do
        expect(purchase.multi_item_charge?).to eq(false)
      end
    end
  end

  describe "#taxed_by_gumroad?" do
    context "when is a Charge" do
      let!(:charge) { create(:charge) }

      before do
        allow(charge).to receive(:taxed_by_gumroad?).and_return("super")
      end

      it "calls super" do
        expect(charge.taxed_by_gumroad?).to eq("super")
      end
    end

    context "when is a Purchase" do
      let(:purchase) { create(:purchase) }

      context "when gumroad_tax_cents is zero" do
        before do
          purchase.update!(gumroad_tax_cents: 0)
        end

        it "returns false" do
          expect(purchase.taxed_by_gumroad?).to eq(false)
        end
      end

      context "when gumroad_tax_cents is greater than zero" do
        before do
          purchase.update!(gumroad_tax_cents: 100)
        end

        it "returns true" do
          expect(purchase.taxed_by_gumroad?).to eq(true)
        end
      end
    end
  end

  describe "#external_id_for_invoice" do
    context "when is a Charge" do
      let!(:charge) { create(:charge) }

      before do
        allow(charge).to receive(:external_id_for_invoice).and_return("super")
      end

      it "calls super" do
        expect(charge.external_id_for_invoice).to eq("super")
      end
    end

    context "when is a Purchase" do
      let(:purchase) { create(:purchase) }

      before do
        allow_any_instance_of(Purchase).to receive(:external_id).and_return("super")
      end

      it "calls super" do
        expect(purchase.external_id_for_invoice).to eq("super")
      end
    end
  end

  describe "#external_id_numeric_for_invoice" do
    context "when is a Charge" do
      let!(:charge) { create(:charge) }

      before do
        allow(charge).to receive(:external_id_numeric_for_invoice).and_return("super")
      end

      it "calls super" do
        expect(charge.external_id_numeric_for_invoice).to eq("super")
      end
    end

    context "when is a Purchase" do
      let(:purchase) { create(:purchase) }

      before do
        allow_any_instance_of(Purchase).to receive(:external_id_numeric).and_return("super")
      end

      it "calls super" do
        expect(purchase.external_id_numeric_for_invoice).to eq("super")
      end
    end
  end

  describe "#subscription" do
    context "when is a Charge" do
      let!(:charge) { build(:charge) }

      it "returns nil" do
        expect(charge.subscription).to eq(nil)
      end
    end

    context "when is a Purchase" do
      let(:subscription) { build(:subscription) }
      let!(:purchase) { build(:purchase, subscription:) }

      it "returns subscription" do
        expect(purchase.subscription).to eq(subscription)
      end
    end
  end
end
