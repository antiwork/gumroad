# frozen_string_literal: true

require "test_helper"

class ChargeChargeableTest < ActiveSupport::TestCase
  self.described_class = Charge::Chargeable



  context_ Charge::Chargeable do
  context_ ".find_by_stripe_event" do
  context_ "for an event on a Purchase" do
  test "finds the purchase using charge reference that is purchase's external id" do
          purchase = create(:purchase, id: 12345)
          event = build(:charge_event_dispute_formalized, charge_reference: purchase.external_id)
          expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(purchase)
        end

  test "finds the purchase using charge id that is purchase's stripe transaction id" do
          purchase = create(:purchase, stripe_transaction_id: "ch_12345")
          event = build(:charge_event_dispute_formalized, charge_reference: nil, charge_id: "ch_12345")
          expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(purchase)
        end

  test "finds the purchase using processor payment intent id" do
          purchase = create(:purchase)
          processor_payment_intent_id = "pi_123456"
          purchase.create_processor_payment_intent!(intent_id: processor_payment_intent_id)
          event = build(:charge_event_dispute_formalized, charge_reference: nil, charge_id: nil, processor_payment_intent_id:)
          expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(purchase)
        end
      end

  context_ "for an event on a Charge" do
  test "finds the charge using charge reference that is charge's id" do
          charge = create(:charge, id: 12345)
          event = build(:charge_event_dispute_formalized, charge_reference: "CH-12345")
          expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(charge)
        end

  test "finds the charge using charge id that is charge's processor transaction id" do
          charge = create(:charge, processor_transaction_id: "ch_12345")
          event = build(:charge_event_dispute_formalized, charge_reference: "CH-12345", charge_id: "ch_12345")
          expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(charge)
        end

  test "finds the charge using processor payment intent id" do
          charge = create(:charge, stripe_payment_intent_id: "pi_123456")
          event = build(:charge_event_dispute_formalized, charge_reference: "CH-12345", charge_id: nil, processor_payment_intent_id: "pi_123456")
          expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(charge)
        end
      end
    end

  context_ ".find_by_processor_transaction_id!" do
      let(:processor_transaction_id) { "ch_123456" }

  context_ "without a matching processor_transaction_id" do
  test "raises an error" do
          expect do
            Charge::Chargeable.find_by_processor_transaction_id!(processor_transaction_id)
          end.to raise_error(ActiveRecord::RecordNotFound)
        end
      end

  context_ "with a matching processor_transaction_id for a purchase" do
        let!(:purchase) { create(:purchase, stripe_transaction_id: processor_transaction_id) }

  test "returns the purchase" do
          expect(Charge::Chargeable.find_by_processor_transaction_id!(processor_transaction_id)).to eq(purchase)
        end

  context_ "with a matching processor_transaction_id for a charge" do
          let!(:charge) { create(:charge, processor_transaction_id:, purchases: [purchase]) }

  test "returns the charge" do
            expect(Charge::Chargeable.find_by_processor_transaction_id!(processor_transaction_id)).to eq(charge)
          end
        end
      end
    end

  context_ ".find_by_purchase_or_charge!" do
  context_ "when both arguments are nil" do
  test "raises an error" do
          expect do
            Charge::Chargeable.find_by_purchase_or_charge!(purchase: nil, charge: nil)
          end.to raise_error(ArgumentError).with_message("Either purchase or charge must be present")
        end
      end

      let(:purchase) { create(:purchase) }

  context_ "when the purchase belongs to a charge" do
        let(:charge) { create(:charge) }

        before do
          charge.purchases << purchase
        end

  context_ "when both arguments are present" do
  test "raises an error" do
            expect do
              Charge::Chargeable.find_by_purchase_or_charge!(purchase:, charge:)
            end.to raise_error(ArgumentError).with_message("Only one of purchase or charge must be present")
          end
        end

  context_ "when the charge_id is provided" do
  test "returns the purchase's charge" do
            expect(Charge::Chargeable.find_by_purchase_or_charge!(purchase:)).to eq(charge)
          end
        end
      end

  context_ "when the purchase does not belong to a charge" do
  test "returns the purchase" do
          expect(Charge::Chargeable.find_by_purchase_or_charge!(purchase:)).to eq(purchase)
        end
      end
    end

  context_ "#support_email" do
      let(:user_level_support_email) { "user-level-support@example.com" }
      let(:product_level_support_email) { "product-level-support@example.com" }
      let(:seller) { create(:named_seller, support_email: user_level_support_email) }

  context_ "on a purchase" do
        let(:chargeable) { create(:purchase, link: product, seller:) }

  context_ "when link's support email is set" do
          let(:product) { create(:product, support_email: product_level_support_email, user: seller) }

  test "returns support_email of the link" do
            expect(chargeable.support_email).to eq(product_level_support_email)
          end
        end

  context_ "when link's support email is not set" do
          let(:product) { create(:product, support_email: nil, user: seller) }

  test "returns seller.support_or_form_email" do
            expect(chargeable.support_email).to eq(user_level_support_email)
          end
        end
      end

  context_ "on a charge" do
  context_ "when all purchases links have the same support email" do
          let(:chargeable) { create(:charge, purchases: [purchase1, purchase2], seller:) }
          let(:product1) { create(:product, support_email: product_level_support_email, user: seller) }
          let(:product2) { create(:product, support_email: product_level_support_email, user: seller) }
          let(:purchase1) { create(:purchase, link: product1, seller:) }
          let(:purchase2) { create(:purchase, link: product2, seller:) }

  test "returns the product level support email" do
            expect(chargeable.support_email).to eq(product_level_support_email)
          end
        end

  context_ "when not all purchases links have the same support email" do
          let(:chargeable) { create(:charge, purchases: [purchase1, purchase2], seller:) }
          let(:product1) { create(:product, support_email: product_level_support_email, user: seller) }
          let(:product2) { create(:product, support_email: nil, user: seller) }
          let(:purchase1) { create(:purchase, link: product1, seller:) }
          let(:purchase2) { create(:purchase, link: product2, seller:) }

  test "returns the user level support email" do
            expect(chargeable.support_email).to eq(user_level_support_email)
          end
        end
      end
    end

  context_ "#charged_purchases" do
  context_ "for a Charge" do
  test "returns an array containing all non-free purchases included in the Charge" do
          purchase1 = create(:purchase)
          purchase2 = create(:purchase)
          purchase3 = create(:purchase)
          free_purchase = create(:free_purchase)
          free_trial_membership_purchase = create(:free_trial_membership_purchase)

          charge = create(:charge, purchases: [purchase1, purchase2, purchase3, free_purchase, free_trial_membership_purchase])

          expect(charge.charged_purchases).to eq([purchase1, purchase2, purchase3])
        end
      end

  context_ "for a Purchase" do
  test "returns a single-item array containing purchase itself" do
          purchase = create(:purchase)
          create(:purchase)
          expect(purchase.charged_purchases).to eq([purchase])
        end
      end
    end

  context_ "#successful_purchases" do
  context_ "for a Charge" do
  test "returns an array containing all purchases included in the Charge" do
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

  context_ "for a Purchase" do
  test "returns the purchase itself" do
          purchase = create(:purchase)
          create(:purchase)
          expect(purchase.successful_purchases).to eq([purchase])
        end
      end
    end

  context_ "#update_processor_fee_cents!", :vcr do
  context_ "for a Purchase" do
  test "updates processor_fee_cents on the purchase" do
          purchase = create(:purchase, total_transaction_cents: 20_00)

          purchase.update_processor_fee_cents!(processor_fee_cents: 2_00)

          expect(purchase.processor_fee_cents).to eq 2_00
        end
      end

  context_ "for a Charge" do
  test "does nothing if input processor_fee_cents is nil" do
          charge = create(:charge, amount_cents: 100_00, processor_fee_cents: nil)
          purchase = create(:purchase, total_transaction_cents: 20_00)
          charge.purchases << purchase

          expect { charge.update_processor_fee_cents!(processor_fee_cents: nil) }.not_to raise_error

          expect(charge.reload.processor_fee_cents).to be nil
          expect(purchase.reload.processor_fee_cents).to be nil
        end

  test "updates processor_fee_cents on included purchases in proper ratio" do
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

  context_ "#charged_amount_cents" do
  context_ "then the chargeable is a charge" do
        let(:charge) { create(:charge, amount_cents: 123_00) }
        let(:purchase1) { create(:purchase, total_transaction_cents: 20_00) }
        let(:purchase2) { create(:purchase, total_transaction_cents: 30_00) }
        let(:purchase3) { create(:purchase, total_transaction_cents: 50_00, purchase_state: "failed") }

        before do
          charge.purchases << purchase1
          charge.purchases << purchase2
          charge.purchases << purchase3
        end

  test "returns the sum of successful purchases" do
          expect(charge.charged_amount_cents).to eq(50_00)
        end
      end

  test "returns the total_transaction_cents for a Purchase" do
        purchase = create(:purchase, total_transaction_cents: 3210)
        expect(purchase.charged_amount_cents).to eq(3210)
      end
    end

  context_ "#charged_gumroad_amount_cents" do
  test "returns the gumroad_amount_cents for a Charge" do
        charge = create(:charge, gumroad_amount_cents: 230)
        expect(charge.charged_gumroad_amount_cents).to eq(230)
      end

  test "returns the total_transaction_amount_for_gumroad_cents for a Purchase" do
        purchase = create(:purchase, total_transaction_cents: 2000, affiliate_credit_cents: 500, fee_cents: 300)
        expect(purchase.charged_gumroad_amount_cents).to eq(purchase.total_transaction_amount_for_gumroad_cents)
      end
    end

  context_ "#unbundled_purchases" do
      let(:seller) { create(:named_seller) }
      let(:product) { create(:product, user: seller, is_bundle: true) }
      let(:chargeable) { create(:purchase, link: product, seller:) }

  context_ "when is not a bundle purchase" do
        before do
          product.update!(is_bundle: false)
        end

  test "returns the same purchase" do
          expect(chargeable.unbundled_purchases).to eq([chargeable])
        end
      end

  context_ "when is a bundle purchase" do
        let!(:bundled_product_one) { create(:bundle_product, bundle: product, product: create(:product, user: seller)) }
        let!(:bundled_product_two) { create(:bundle_product, bundle: product, product: create(:product, user: seller)) }

        before do
          chargeable.create_artifacts_and_send_receipt!
        end

  test "returns purchases for bundled products" do
          expect(chargeable.unbundled_purchases.size).to eq(2)
          expect(chargeable.unbundled_purchases.first.link).to eq(bundled_product_one.product)
          expect(chargeable.unbundled_purchases.second.link).to eq(bundled_product_two.product)
        end
      end
    end

  context_ "#is_recurring_subscription_charge" do
  context_ "when is a Charge" do
        let(:charge) { create(:charge) }

  test "returns false" do
          expect(charge.is_recurring_subscription_charge).to eq(false)
        end
      end

  context_ "when is a Purchase" do
        let(:original_membership_purchase) { create(:membership_purchase) }
        let!(:recurring_membership_purchase) do
          create(:purchase, link: original_membership_purchase.link, subscription: original_membership_purchase.subscription)
        end

  context_ "when the purchase is the original purchase" do
  test "returns false" do
            expect(original_membership_purchase.is_recurring_subscription_charge).to eq(false)
          end
        end

  context_ "when the purchase is a recurring purchase" do
  test "returns true" do
            expect(recurring_membership_purchase.is_recurring_subscription_charge).to eq(true)
          end
        end
      end
    end

  context_ "#taxable?" do
  context_ "when is a Charge" do
        let(:charge) { create(:charge) }

        before do
          allow(charge).to receive(:taxable?).and_return("super")
        end

  test "calls super" do
          expect(charge.taxable?).to eq("super")
        end
      end

  context_ "when is a Purchase" do
        let(:purchase) { create(:purchase) }

        before do
          allow_any_instance_of(Purchase).to receive(:was_purchase_taxable?).and_return("super")
        end

  test "calls super" do
          expect(purchase.taxable?).to eq("super")
        end
      end
    end

  context_ "#multi_item_charge?" do
  context_ "when is a Charge" do
  context_ "with one purchase" do
          let(:charge) { create(:charge, purchases: [create(:purchase)]) }

  test "returns false" do
            expect(charge.multi_item_charge?).to eq(false)
          end
        end

  context_ "with multiple purchases" do
          let(:charge) { create(:charge, purchases: [create(:purchase), create(:purchase)]) }

  test "returns true" do
            expect(charge.multi_item_charge?).to eq(true)
          end
        end
      end

  context_ "when is a Purchase" do
        let(:purchase) { create(:purchase) }

  test "returns false" do
          expect(purchase.multi_item_charge?).to eq(false)
        end
      end
    end

  context_ "#taxed_by_gumroad?" do
  context_ "when is a Charge" do
        let!(:charge) { create(:charge) }

        before do
          allow(charge).to receive(:taxed_by_gumroad?).and_return("super")
        end

  test "calls super" do
          expect(charge.taxed_by_gumroad?).to eq("super")
        end
      end

  context_ "when is a Purchase" do
        let(:purchase) { create(:purchase) }

  context_ "when gumroad_tax_cents is zero" do
          before do
            purchase.update!(gumroad_tax_cents: 0)
          end

  test "returns false" do
            expect(purchase.taxed_by_gumroad?).to eq(false)
          end
        end

  context_ "when gumroad_tax_cents is greater than zero" do
          before do
            purchase.update!(gumroad_tax_cents: 100)
          end

  test "returns true" do
            expect(purchase.taxed_by_gumroad?).to eq(true)
          end
        end
      end
    end

  context_ "#external_id_for_invoice" do
  context_ "when is a Charge" do
        let!(:charge) { create(:charge) }

        before do
          allow(charge).to receive(:external_id_for_invoice).and_return("super")
        end

  test "calls super" do
          expect(charge.external_id_for_invoice).to eq("super")
        end
      end

  context_ "when is a Purchase" do
        let(:purchase) { create(:purchase) }

        before do
          allow_any_instance_of(Purchase).to receive(:external_id).and_return("super")
        end

  test "calls super" do
          expect(purchase.external_id_for_invoice).to eq("super")
        end
      end
    end

  context_ "#external_id_numeric_for_invoice" do
  context_ "when is a Charge" do
        let!(:charge) { create(:charge) }

        before do
          allow(charge).to receive(:external_id_numeric_for_invoice).and_return("super")
        end

  test "calls super" do
          expect(charge.external_id_numeric_for_invoice).to eq("super")
        end
      end

  context_ "when is a Purchase" do
        let(:purchase) { create(:purchase) }

        before do
          allow_any_instance_of(Purchase).to receive(:external_id_numeric).and_return("super")
        end

  test "calls super" do
          expect(purchase.external_id_numeric_for_invoice).to eq("super")
        end
      end
    end

  context_ "#subscription" do
  context_ "when is a Charge" do
        let!(:charge) { build(:charge) }

  test "returns nil" do
          expect(charge.subscription).to eq(nil)
        end
      end

  context_ "when is a Purchase" do
        let(:subscription) { build(:subscription) }
        let!(:purchase) { build(:purchase, subscription:) }

  test "returns subscription" do
          expect(purchase.subscription).to eq(subscription)
        end
      end
    end
  end
end
