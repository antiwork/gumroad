# frozen_string_literal: true

require "spec_helper"
require "business/payments/charging/charge_shared_examples"

describe StripeCharge, :vcr do
  include StripeMerchantAccountHelper
  include StripeChargesHelper

  let(:currency) { Currency::USD }

  let(:amount_cents) { 1_00 }

  let(:stripe_charge) do
    stripe_charge = create_stripe_charge(StripePaymentMethodHelper.success.to_stripejs_payment_method_id,
                                         amount: amount_cents,
                                         currency:
    )
    Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[balance_transaction])
  end

  let(:subject) { described_class.new(stripe_charge, stripe_charge.balance_transaction, nil, nil, nil) }

  it_behaves_like "a base processor charge"

  describe "#initialize" do
    describe "with a stripe charge" do
      it "has a charge_processor_id set to 'stripe'" do
        expect(subject.charge_processor_id).to eq "stripe"
      end

      it "has the correct #id" do
        expect(subject.id).to eq stripe_charge.id
      end

      it "has the correct #refunded" do
        expect(subject.refunded).to be(false)
      end

      it "has the correct #fee" do
        expect(subject.fee).to eq stripe_charge.balance_transaction.fee
      end

      it "has the correct #fee_currency" do
        expect(subject.fee_currency).to eq stripe_charge.balance_transaction.currency
      end

      it "has the correct #card_fingerprint" do
        expect(subject.card_fingerprint).to eq stripe_charge.payment_method_details.card.fingerprint
      end

      it "has the correct #card_instance_id" do
        expect(subject.card_instance_id).to eq stripe_charge.payment_method
      end

      it "has the correct #card_last4" do
        expect(subject.card_last4).to eq stripe_charge.payment_method_details.card.last4
      end

      it "has the correct #card_number_length" do
        expect(subject.card_number_length).to eq 16
      end

      it "has the correct #card_expiry_month" do
        expect(subject.card_expiry_month).to eq stripe_charge.payment_method_details.card.exp_month
      end

      it "has the correct #card_expiry_year" do
        expect(subject.card_expiry_year).to eq stripe_charge.payment_method_details.card.exp_year
      end

      it "has the correct #card_zip_code" do
        expect(subject.card_zip_code).to eq stripe_charge.billing_details.address.postal_code
      end

      it "has the correct #card_type" do
        expect(subject.card_type).to eq "visa"
      end

      it "has the correct #card_zip_code" do
        expect(subject.card_country).to eq stripe_charge.payment_method_details.card.country
      end

      it "has the correct #zip_check_result" do
        expect(subject.zip_check_result).to be(nil)
      end

      it "has a simple flow of funds" do
        expect(subject.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
        expect(subject.flow_of_funds.issued_amount.cents).to eq(amount_cents)
        expect(subject.flow_of_funds.settled_amount.currency).to eq(Currency::USD)
        expect(subject.flow_of_funds.settled_amount.cents).to eq(amount_cents)
        expect(subject.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
        expect(subject.flow_of_funds.gumroad_amount.cents).to eq(amount_cents)
        expect(subject.flow_of_funds.merchant_account_gross_amount).to be_nil
        expect(subject.flow_of_funds.merchant_account_net_amount).to be_nil
      end

      it "sets the correct risk_level" do
        expect(subject.risk_level).to eq stripe_charge.outcome.risk_level
      end

      it "initializes correctly without the stripe fee info" do
        stripe_charge.balance_transaction.fee_details = []

        expect(subject.fee).to be(nil)
        expect(subject.fee_currency).to be(nil)
      end
    end

    describe "with a stripe charge with pass zip check" do
      let(:stripe_charge) do
        stripe_charge = create_stripe_charge(StripePaymentMethodHelper.success.with_zip_code.to_stripejs_payment_method_id,
                                             amount: amount_cents,
                                             currency:
        )
        Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[balance_transaction])
      end

      let(:subject) { described_class.new(stripe_charge, stripe_charge.balance_transaction, nil, nil, nil) }

      it "has the correct #zip_check_result" do
        expect(subject.zip_check_result).to be(true)
      end
    end

    # NOTE: There is no test for failed zip check because Gumroad has Stripe configured to raise an error if we
    # attempt to process with an incorrect zip. This means that under the current Stripe configuration the
    # zip_check_result will never be false since we do not create Charge object when an error is raised.
    # If the Stripe configuration changes in the future then a test should be added for this scenario.

    describe "with a stripe charge destined for a managed account" do
      let(:application_fee) { 50 }

      let(:destination_currency) { Currency::CAD }

      let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: destination_currency) }

      let(:stripe_charge) do
        stripe_charge = create_stripe_charge(StripePaymentMethodHelper.success.to_stripejs_payment_method_id,
                                             amount: amount_cents,
                                             currency:,
                                             transfer_data: { destination: stripe_managed_account.id, amount: amount_cents - application_fee },
        )
        Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[balance_transaction application_fee.balance_transaction])
      end

      let(:stripe_destination_transfer) do
        Stripe::Transfer.retrieve(id: stripe_charge.transfer)
      end

      let(:stripe_destination_payment) do
        destination_transfer = Stripe::Transfer.retrieve(id: stripe_charge.transfer)
        Stripe::Charge.retrieve({ id: destination_transfer.destination_payment,
                                  expand: %w[balance_transaction refunds.data.balance_transaction application_fee.refunds] },
                                { stripe_account: destination_transfer.destination })
      end

      let(:subject) do
        described_class.new(stripe_charge, stripe_charge.balance_transaction,
                            stripe_charge.application_fee.try(:balance_transaction),
                            stripe_destination_payment.balance_transaction, stripe_destination_transfer)
      end

      describe "#flow_of_funds" do
        let(:flow_of_funds) { subject.flow_of_funds }

        describe "#issued_amount" do
          let(:issued_amount) { flow_of_funds.issued_amount }

          it "matches the currency the buyer was charged in" do
            expect(issued_amount.currency).to eq(currency)
          end

          it "matches the amount the buyer was charged" do
            expect(issued_amount.cents).to eq(amount_cents)
          end
        end

        describe "#settled_amount" do
          let(:settled_amount) { flow_of_funds.settled_amount }

          it "matches the currency the destinations default currency" do
            expect(settled_amount.currency).to eq(stripe_charge.balance_transaction.currency)
          end

          it "does not match the currency the destination received in" do
            expect(settled_amount.currency).not_to eq(stripe_destination_payment.balance_transaction.currency)
          end

          it "matches the amount the destination received" do
            expect(settled_amount.cents).to eq(stripe_charge.balance_transaction.amount)
          end
        end

        describe "#gumroad_amount" do
          let(:gumroad_amount) { flow_of_funds.gumroad_amount }

          it "matches the currency of gumroads account (usd)" do
            expect(gumroad_amount.currency).to eq(Currency::USD)
          end

          it "matches the currency that gumroad received the application fee in" do
            expect(gumroad_amount.currency).to eq(stripe_charge.currency)
          end

          it "matches the amount of the application fee received in gumroads account" do
            expect(gumroad_amount.cents).to eq(stripe_charge.amount - stripe_destination_transfer.amount)
          end
        end

        describe "#merchant_account_gross_amount" do
          let(:merchant_account_gross_amount) { flow_of_funds.merchant_account_gross_amount }

          it "matches the currency the destinations default currency" do
            expect(merchant_account_gross_amount.currency).to eq(destination_currency)
          end

          it "matches the currency the destination received in" do
            expect(merchant_account_gross_amount.currency).to eq(stripe_destination_payment.balance_transaction.currency)
          end

          it "matches the amount the destination received" do
            expect(merchant_account_gross_amount.cents).to eq(stripe_destination_payment.balance_transaction.amount)
          end
        end

        describe "#merchant_account_net_amount" do
          let(:merchant_account_net_amount) { flow_of_funds.merchant_account_net_amount }

          it "matches the currency the destinations default currency" do
            expect(merchant_account_net_amount.currency).to eq(destination_currency)
          end

          it "matches the currency the destination received in" do
            expect(merchant_account_net_amount.currency).to eq(stripe_destination_payment.balance_transaction.currency)
          end

          it "matches the amount the destination received after taking out gumroads application fee" do
            expect(merchant_account_net_amount.cents).to eq(stripe_destination_payment.balance_transaction.net)
          end
        end
      end
    end
  end
end
