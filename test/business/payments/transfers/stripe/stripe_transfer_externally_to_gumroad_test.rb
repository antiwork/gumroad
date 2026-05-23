# frozen_string_literal: true

require "test_helper"

class StripeTransferExternallyToGumroadTest < ActiveSupport::TestCase
  self.described_class = StripeTransferExternallyToGumroad
  self.rspec_metadata = { vcr: true }


  context_ StripeTransferExternallyToGumroad, :vcr do
    include StripeChargesHelper

  context_ "available balances" do
      let(:available_balances) { described_class.available_balances }
      before do
        # ensure the available balance has positive value
        create_stripe_charge(StripePaymentMethodHelper.success_available_balance.to_stripejs_payment_method_id,
                             amount: 100,
                             currency: "usd"
        )
        expect(!available_balances.empty?).to eq(true)
      end

  context_ "available_balances" do
  test "returns a hash of currencies to balances in cents" do
          expect(available_balances).to be_a(Hash)
          expect(available_balances.keys).to include("usd")
          available_balances.each do |_currency, balance_cents|
            expect(balance_cents).to be_a(Integer)
          end
        end
      end

  context_ "transfer" do
  test "transfers the currency and balance using stripe to the Gumroad recipient" do
          expect(Stripe::Payout).to receive(:create).with(hash_including(
                                                            amount: 1234,
                                                            currency: "usd",
                                                            ))
          travel_to(Time.zone.local(2015, 4, 7)) do
            described_class.transfer("usd", 1234)
          end
        end

  test "sets the description (which shows up in the stripe dashboard)" do
          expect(Stripe::Payout).to receive(:create).with(hash_including(
                                                            description: "USD 150407 0000"
                                                            ))
          travel_to(Time.zone.local(2015, 4, 7)) do
            described_class.transfer("usd", 1234)
          end
        end
      end

  context_ "transfer_all_available_balances" do
  context_ "with balance" do
          before do
            expect(described_class).to receive(:available_balances).and_return("usd" => 100_00)
          end

  test "creates a stripe transfer for each available balance" do
            expect(described_class).to receive(:transfer).with("usd", 100_00)
            described_class.transfer_all_available_balances
          end
        end

  context_ "with balance greater than 99_999_999_99 cents" do
          before do
            expect(described_class).to receive(:available_balances).and_return("usd" => 100_000_000_00)
          end

  test "creates a stripe transfer for 99_999_999_99 cents" do
            expect(described_class).to receive(:transfer).with("usd", 99_999_999_99)
            described_class.transfer_all_available_balances
          end
        end

  context_ "zero balance" do
          before do
            expect(described_class).to receive(:available_balances).and_return("usd" => 0, "cad" => 100)
          end

  test "does not attempt to transfer" do
            expect(described_class).not_to receive(:transfer).with("usd", anything)
            expect(described_class).to receive(:transfer).with("cad", 100)
            described_class.transfer_all_available_balances
          end
        end

  context_ "negative balance" do
          before do
            expect(described_class).to receive(:available_balances).and_return("usd" => -100, "cad" => 100)
          end

  test "does not attempt to transfer" do
            expect(described_class).not_to receive(:transfer).with("usd", anything)
            expect(described_class).to receive(:transfer).with("cad", 100)
            described_class.transfer_all_available_balances
          end
        end

  context_ "with buffer" do
          let(:buffer_cents) { 50 }

  context_ "with balance" do
  test "creates a stripe transfer for each available balance" do
              available_balances.each do |currency, balance_cents|
                expect(described_class).to receive(:transfer).with(currency, balance_cents - 50) if balance_cents > 0
              end
              described_class.transfer_all_available_balances(buffer_cents:)
            end
          end

  context_ "zero balance" do
            before do
              expect(described_class).to receive(:available_balances).and_return("usd" => 0, "cad" => 100)
            end

  test "does not attempt to transfer" do
              expect(described_class).not_to receive(:transfer).with("usd", anything)
              expect(described_class).to receive(:transfer).with("cad", 50)
              described_class.transfer_all_available_balances(buffer_cents:)
            end
          end

  context_ "negative balance" do
            before do
              expect(described_class).to receive(:available_balances).and_return("usd" => -100, "cad" => 100)
            end

  test "does not attempt to transfer" do
              expect(described_class).not_to receive(:transfer).with("usd", anything)
              expect(described_class).to receive(:transfer).with("cad", 50)
              described_class.transfer_all_available_balances(buffer_cents:)
            end
          end
        end
      end
    end
  end
end
