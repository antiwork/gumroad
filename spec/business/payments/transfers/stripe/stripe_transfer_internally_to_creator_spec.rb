# frozen_string_literal: true

describe StripeTransferInternallyToCreator, :vcr do
  include StripeMerchantAccountHelper
  include StripeChargesHelper

  describe "transfer_funds_to_account" do
    before do
      # ensure the available balance has positive value
      create_stripe_charge(StripePaymentMethodHelper.success_available_balance.to_stripejs_payment_method_id,
                           amount: 100_000_00,
                           currency: "usd"
      )
    end

    let(:managed_account) { create_verified_stripe_account(country: "US") }
    let(:managed_account_id) { managed_account.id }

    describe "transfer_funds_to_account" do
      describe "when no related charge given" do
        it "creates a transfer at stripe destined for the connected account" do
          expect(Stripe::Transfer).to receive(:create).with(hash_including(
                                                              destination: managed_account_id,
                                                              currency: "usd",
                                                              amount: 1_000_00,
                                                              description: "message_why",
                                                              metadata: nil
                                                            )).and_call_original
          subject.transfer_funds_to_account(message_why: "message_why",
                                            stripe_account_id: managed_account_id,
                                            currency: Currency::USD,
                                            amount_cents: 1_000_00)
        end

        it "returns a transfer that has balance transactions for itself and for the application fee" do
          transfer = subject.transfer_funds_to_account(message_why: "message_why",
                                                       stripe_account_id: managed_account_id,
                                                       currency: Currency::USD,
                                                       amount_cents: 1_000_00)
          expect(transfer.balance_transaction).to be_a(Stripe::BalanceTransaction)
        end
      end

      describe "when a related charge is given" do
        it "creates a transfer at stripe destined for the connected account" do
          expect(Stripe::Transfer).to receive(:create).with(hash_including(
                                                              destination: managed_account_id,
                                                              currency: "usd",
                                                              amount: 1_000_00,
                                                              description: "message_why Related Charge ID: charge-id.",
                                                              metadata: nil
                                                            )).and_call_original
          subject.transfer_funds_to_account(message_why: "message_why",
                                            stripe_account_id: managed_account_id,
                                            currency: Currency::USD,
                                            amount_cents: 1_000_00,
                                            related_charge_id: "charge-id")
        end

        it "returns a transfer that has balance transactions for itself and for the application fee" do
          transfer = subject.transfer_funds_to_account(message_why: "message_why",
                                                       stripe_account_id: managed_account_id,
                                                       currency: Currency::USD,
                                                       amount_cents: 1_000_00)
          expect(transfer.balance_transaction).to be_a(Stripe::BalanceTransaction)
        end
      end

      describe "when metadata is given" do
        it "creates a transfer with the given metadata" do
          expect(Stripe::Transfer).to receive(:create).with(hash_including(
                                                              destination: managed_account_id,
                                                              currency: "usd",
                                                              amount: 1_000_00,
                                                              description: "message_why",
                                                              metadata: {
                                                                metadata_1: "metadata_1",
                                                                metadata_2: 1234,
                                                                metadata_3: "metadata_2_a,metadata_2_a"
                                                              }
                                                            )).and_call_original
          subject.transfer_funds_to_account(message_why: "message_why",
                                            stripe_account_id: managed_account_id,
                                            currency: Currency::USD,
                                            amount_cents: 1_000_00,
                                            metadata: {
                                              metadata_1: "metadata_1",
                                              metadata_2: 1234,
                                              metadata_3: %w[metadata_2_a metadata_2_a].join(",")
                                            })
        end
      end
    end
  end
end
