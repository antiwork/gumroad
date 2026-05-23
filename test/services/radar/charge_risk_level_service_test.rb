# frozen_string_literal: true

require "test_helper"

class RadarChargeRiskLevelServiceTest < ActiveSupport::TestCase
  self.described_class = Radar::ChargeRiskLevelService



  context_ Radar::ChargeRiskLevelService do
    def create_test_purchase(**overrides)
      purchase = build(:purchase, **overrides)
      purchase.save!(validate: false)
      purchase
    end

    def create_test_purchase_with_unique_stripe_transaction_id
      purchase = create_test_purchase
      purchase.update_column(:stripe_transaction_id, "ch_unique_#{purchase.id}")
      purchase
    end

  context_ ".fetch" do
      let(:purchase) { create_test_purchase }

  test "returns nil for purchases without stripe_transaction_id" do
        purchase.update_column(:stripe_transaction_id, nil)
        expect(described_class.fetch(purchase)).to be_nil
      end

  test "returns nil for non-Stripe purchases" do
        purchase.update_column(:charge_processor_id, "paypal")
        expect(described_class.fetch(purchase)).to be_nil
      end

  test "fetches risk level from Stripe and caches it" do
        stripe_charge = Stripe::Charge.construct_from(outcome: { risk_level: "elevated" })
        expect(Stripe::Charge).to receive(:retrieve).with(purchase.stripe_transaction_id).once.and_return(stripe_charge)

        expect(described_class.fetch(purchase)).to eq("elevated")
        # Second call uses cache
        expect(described_class.fetch(purchase)).to eq("elevated")
      end

  test "returns nil when the charge has no risk assessment" do
        stripe_charge = Stripe::Charge.construct_from(outcome: nil)
        expect(Stripe::Charge).to receive(:retrieve).with(purchase.stripe_transaction_id).once.and_return(stripe_charge)

        expect(described_class.fetch(purchase)).to be_nil
      end

  context_ "with a Stripe Connect merchant account" do
        let(:merchant_account) { create(:merchant_account_stripe_connect) }

        before do
          purchase.update_column(:merchant_account_id, merchant_account.id)
          purchase.reload
        end

  test "fetches from the connect account" do
          stripe_charge = Stripe::Charge.construct_from(outcome: { risk_level: "highest" })
          expect(Stripe::Charge).to receive(:retrieve).with(
            { id: purchase.stripe_transaction_id },
            { stripe_account: merchant_account.charge_processor_merchant_id }
          ).and_return(stripe_charge)

          expect(described_class.fetch(purchase)).to eq("highest")
        end

  test "falls back to Gumroad account on connect account error" do
          stripe_charge = Stripe::Charge.construct_from(outcome: { risk_level: "normal" })
          expect(Stripe::Charge).to receive(:retrieve).with(
            { id: purchase.stripe_transaction_id },
            { stripe_account: merchant_account.charge_processor_merchant_id }
          ).and_raise(StandardError.new("Not found"))
          expect(Stripe::Charge).to receive(:retrieve).with(purchase.stripe_transaction_id).and_return(stripe_charge)

          expect(described_class.fetch(purchase)).to eq("normal")
        end
      end

  test "returns nil on Stripe error" do
        expect(Stripe::Charge).to receive(:retrieve).and_raise(Stripe::StripeError.new("API error"))
        expect(described_class.fetch(purchase)).to be_nil
      end
    end

  context_ ".fetch_bulk" do
      let(:purchase) { create_test_purchase }
      let(:purchase2) { create_test_purchase_with_unique_stripe_transaction_id }

  test "bulk fetches risk levels and skips non-Stripe purchases" do
        non_stripe = create_test_purchase
        non_stripe.update_column(:stripe_transaction_id, nil)

        charge1 = Stripe::Charge.construct_from(outcome: { risk_level: "normal" })
        charge2 = Stripe::Charge.construct_from(outcome: { risk_level: "elevated" })

        expect(Stripe::Charge).to receive(:retrieve).with(purchase.stripe_transaction_id).and_return(charge1)
        expect(Stripe::Charge).to receive(:retrieve).with(purchase2.stripe_transaction_id).and_return(charge2)

        results = described_class.fetch_bulk([purchase, purchase2, non_stripe])

        expect(results[purchase.id]).to eq("normal")
        expect(results[purchase2.id]).to eq("elevated")
        expect(results).not_to have_key(non_stripe.id)
      end

  test "caches nil results and does not re-fetch from Stripe" do
        charge = Stripe::Charge.construct_from(outcome: { risk_level: nil })
        expect(Stripe::Charge).to receive(:retrieve).with(purchase.stripe_transaction_id).once.and_return(charge)

        # First bulk fetch — calls Stripe, gets nil
        results = described_class.fetch_bulk([purchase])
        expect(results[purchase.id]).to be_nil

        # Second bulk fetch — should use cache, not re-fetch
        results = described_class.fetch_bulk([purchase])
        expect(results[purchase.id]).to be_nil
      end

  test "caches nil results when charge outcome is nil and does not re-fetch from Stripe" do
        charge = Stripe::Charge.construct_from(outcome: nil)
        expect(Stripe::Charge).to receive(:retrieve).with(purchase.stripe_transaction_id).once.and_return(charge)

        results = described_class.fetch_bulk([purchase])
        expect(results[purchase.id]).to be_nil

        results = described_class.fetch_bulk([purchase])
        expect(results[purchase.id]).to be_nil
      end

  test "uses cache for already-fetched purchases" do
        charge = Stripe::Charge.construct_from(outcome: { risk_level: "highest" })
        expect(Stripe::Charge).to receive(:retrieve).with(purchase.stripe_transaction_id).once.and_return(charge)

        described_class.fetch_bulk([purchase])
        results = described_class.fetch_bulk([purchase])
        expect(results[purchase.id]).to eq("highest")
      end

  test "deduplicates purchases sharing the same stripe_transaction_id" do
        shared_txn_id = purchase.stripe_transaction_id
        duplicate = create_test_purchase
        duplicate.update_column(:stripe_transaction_id, shared_txn_id)

        charge = Stripe::Charge.construct_from(outcome: { risk_level: "elevated" })
        expect(Stripe::Charge).to receive(:retrieve).with(shared_txn_id).once.and_return(charge)

        results = described_class.fetch_bulk([purchase, duplicate])
        expect(results[purchase.id]).to eq("elevated")
        expect(results[duplicate.id]).to eq("elevated")
      end
    end
  end
end
