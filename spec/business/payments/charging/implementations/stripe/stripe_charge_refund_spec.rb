# frozen_string_literal: true

require "spec_helper"

describe StripeChargeRefund, :vcr do
  include StripeMerchantAccountHelper
  include StripeChargesHelper

  let(:currency) { Currency::USD }

  let(:amount_cents) { 1_00 }

  let(:stripe_charge) do
    create_stripe_charge(StripePaymentMethodHelper.success.to_stripejs_payment_method_id,
                         amount: amount_cents,
                         currency:,
    )
  end

  let(:stripe_refund) do
    Stripe::Refund.create(
      charge: stripe_charge[:id],
      expand: %w[balance_transaction]
    )
  end

  let(:subject) do
    described_class.new(stripe_charge, stripe_refund, nil, stripe_refund.balance_transaction, nil, nil, nil)
  end

  describe "#initialize" do
    describe "with a stripe refund" do
      it "has a charge_processor_id set to 'stripe'" do
        expect(subject.charge_processor_id).to eq "stripe"
      end

      it "has the #id from the stripe refund" do
        expect(subject.id).to eq(stripe_refund[:id])
      end

      it "has the #charge_id from the stripe refund" do
        expect(subject.charge_id).to eq(stripe_refund[:charge])
      end

      it "has the #charge_id from the original stripe charge" do
        expect(subject.charge_id).to eq(stripe_charge[:id])
      end
    end

    describe "with a stripe refund for a charge that was destined for a managed account" do
      let(:application_fee) { 50 }

      let(:destination_currency) { Currency::CAD }

      let(:stripe_managed_account) { create_verified_stripe_account(country: "CA", default_currency: destination_currency) }

      let(:stripe_charge) do
        create_stripe_charge(StripePaymentMethodHelper.success.to_stripejs_payment_method_id,
                             amount: amount_cents,
                             currency:,
                             transfer_data: { destination: stripe_managed_account.id, amount: amount_cents - application_fee },
        )
      end

      let(:stripe_refund_additional_params) do
        {}
      end

      let(:stripe_refund_params) do
        {
          charge: stripe_charge[:id],
          expand: %w[balance_transaction]
        }.merge(stripe_refund_additional_params)
      end

      let(:stripe_refund) { Stripe::Refund.create(stripe_refund_params) }

      before do
        stripe_refund
      end

      let(:stripe_charge_refreshed) do
        # A bug in the Stripe ruby gem causes it to lose it's expanded objects if it is refreshed after it's been created.
        # Re-retrieving it anew solves this problem as refreshes of a retrieve charged refresh and maintain the expanded objects.
        Stripe::Charge.retrieve(id: stripe_charge.id, expand: %w[balance_transaction application_fee.refunds.data.balance_transaction])
      end

      let(:stripe_destination_payment) do
        destination_transfer = Stripe::Transfer.retrieve(id: stripe_charge_refreshed.transfer)
        Stripe::Charge.retrieve({ id: destination_transfer.destination_payment,
                                  expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                { stripe_account: destination_transfer.destination })
      end

      let(:stripe_destination_payment_refund) { stripe_destination_payment.refunds.first }
      let(:stripe_refund_bt) { stripe_refund.balance_transaction }

      let(:subject) do
        described_class.new(
          stripe_charge_refreshed,
          stripe_refund,
          stripe_destination_payment,
          stripe_refund_bt,
          nil,
          stripe_destination_payment_refund.try(:balance_transaction),
          nil
        )
      end

      describe "that involves the destination" do
        let(:stripe_refund_additional_params) do
          {
            reverse_transfer: true,
            refund_application_fee: true
          }
        end

        describe "#flow_of_funds" do
          let(:flow_of_funds) { subject.flow_of_funds }

          describe "#issued_amount" do
            let(:issued_amount) { flow_of_funds.issued_amount }

            it "matches the currency the buyer was charged in" do
              expect(issued_amount.currency).to eq(currency)
            end

            it "matches the amount the buyer was charged" do
              expect(issued_amount.cents).to eq(-amount_cents)
            end
          end

          describe "#settled_amount" do
            let(:settled_amount) { flow_of_funds.settled_amount }

            it "matches the currency of the transaction was made in " do
              expect(settled_amount.currency).to eq(Currency::USD)
            end

            it "matches the currency the refund was withdrawn from" do
              expect(settled_amount.currency).to eq(stripe_refund_bt.currency)
            end

            it "matches the amount withdrawn" do
              expect(settled_amount.cents).to eq(stripe_refund_bt.amount)
            end
          end

          describe "#gumroad_amount" do
            let(:gumroad_amount) { flow_of_funds.gumroad_amount }

            it "matches the currency of gumroads account (usd)" do
              expect(gumroad_amount.currency).to eq(Currency::USD)
            end

            it "matches the currency of the Stripe refund" do
              expect(gumroad_amount.currency).to eq(stripe_refund_bt.currency)
            end

            it "matches the amount of the Stripe refund" do
              expect(gumroad_amount.cents).to eq(stripe_charge.amount - stripe_destination_payment.amount)
            end
          end

          describe "#merchant_account_gross_amount" do
            let(:merchant_account_gross_amount) { flow_of_funds.merchant_account_gross_amount }

            it "matches the currency the destinations default currency" do
              expect(merchant_account_gross_amount.currency).to eq(destination_currency)
            end

            it "matches the currency the destination payment is refunded in" do
              expect(merchant_account_gross_amount.currency).to eq(stripe_destination_payment_refund.balance_transaction.currency)
            end

            it "matches the amount of the destination payment refund" do
              expect(merchant_account_gross_amount.cents).to eq(
                stripe_destination_payment_refund.balance_transaction.amount
              )
            end
          end

          describe "#merchant_account_net_amount" do
            let(:merchant_account_net_amount) { flow_of_funds.merchant_account_net_amount }

            it "matches the currency the destinations default currency" do
              expect(merchant_account_net_amount.currency).to eq(destination_currency)
            end

            it "matches the currency the destination payment is refunded in" do
              expect(merchant_account_net_amount.currency).to eq(stripe_destination_payment_refund.balance_transaction.currency)
            end

            it "matches the amount of the destination payment refund minus Gumroad's application fee refund amount" do
              expect(merchant_account_net_amount.cents).to eq(
                stripe_destination_payment_refund.balance_transaction.amount
              )
            end
          end
        end
      end

      describe "that doesn't involve the destination" do
        let(:refunded_amount_cents) { 0_30 }

        let(:stripe_refund_additional_params) do
          {
            amount: refunded_amount_cents
          }
        end

        describe "some sanity checks on what we expect from stripe" do
          it "Stripe should not have refunded the destination payment" do
            expect(stripe_destination_payment_refund).to eq(nil)
          end
        end

        describe "#flow_of_funds" do
          let(:flow_of_funds) { subject.flow_of_funds }
          let(:issued_amount) { flow_of_funds.issued_amount }

          describe "#issued_amount" do
            it "matches the currency the buyer was charged in" do
              expect(issued_amount.currency).to eq(currency)
            end

            it "matches the amount the buyer was charged" do
              expect(issued_amount.cents).to eq(-refunded_amount_cents)
            end
          end

          describe "#settled_amount" do
            let(:settled_amount) { flow_of_funds.settled_amount }

            it "matches the currency of that the transaction was made in as fallback (cad)" do
              expect(settled_amount.currency).to eq(stripe_refund_bt.currency)
            end

            it "matches the amount withdrawn" do
              expect(settled_amount.cents).to eq(stripe_refund_bt.amount)
            end
          end

          describe "#gumroad_amount" do
            let(:gumroad_amount) { flow_of_funds.gumroad_amount }

            it "matches the currency of that the transaction was made in (usd)" do
              expect(gumroad_amount.currency).to eq(stripe_refund.currency)
            end

            it "matches the amount taken from the funds that gumroad holds (settled amount as fallback)" do
              expect(gumroad_amount.cents).to eq(-stripe_refund.amount)
            end
          end

          describe "#merchant_account_gross_amount" do
            let(:merchant_account_gross_amount) { flow_of_funds.merchant_account_gross_amount }

            it "is nil" do
              expect(merchant_account_gross_amount).to eq(nil)
            end
          end

          describe "#merchant_account_net_amount" do
            let(:merchant_account_net_amount) { flow_of_funds.merchant_account_net_amount }

            it "is nil" do
              expect(merchant_account_net_amount).to eq(nil)
            end
          end
        end
      end
    end
  end

  # gumroad-private#1608: the charge side records zero in the account's own currency for a
  # destination payment Stripe never credited. The reversal has to agree — balances are keyed on
  # holding_currency, so a debit in any other currency lands on a different Balance row than the
  # credit it reverses, and a non-USD row on a Gumroad-held balance blocks the seller's payout.
  describe "reversing a destination payment that was never credited" do
    let(:merchant_account_currency) { Currency::EUR }

    let(:uncredited_charge) do
      Stripe::Charge.construct_from(id: "ch_test_1608", currency: "usd", amount: 93,
                                    destination: "acct_test_1608", transfer: "tr_test_1608",
                                    application_fee: nil)
    end

    let(:uncredited_refund) do
      Stripe::Refund.construct_from(id: "re_test_1608", charge: "ch_test_1608",
                                    currency: "usd", amount: 93)
    end

    let(:refund_balance_transaction) do
      Stripe::BalanceTransaction.construct_from(id: "txn_test_1608r", currency: "usd", amount: -93)
    end

    let(:flow_of_funds) do
      described_class.new(uncredited_charge, uncredited_refund, nil, refund_balance_transaction,
                          nil, nil, nil,
                          destination_payment_uncredited: true,
                          merchant_account_currency:).flow_of_funds
    end

    it "reverses the merchant account amounts to zero in the account's own currency" do
      expect(flow_of_funds.merchant_account_gross_amount.currency).to eq(Currency::EUR)
      expect(flow_of_funds.merchant_account_gross_amount.cents).to eq(0)
      expect(flow_of_funds.merchant_account_net_amount.currency).to eq(Currency::EUR)
      expect(flow_of_funds.merchant_account_net_amount.cents).to eq(0)
    end

    it "returns the whole refund from Gumroad's side, since the account was credited nothing" do
      expect(flow_of_funds.gumroad_amount.currency).to eq("usd")
      expect(flow_of_funds.gumroad_amount.cents).to eq(-93)
    end

    it "keeps the issued and settled amounts unchanged" do
      expect(flow_of_funds.issued_amount.cents).to eq(-93)
      expect(flow_of_funds.settled_amount.cents).to eq(-93)
    end

    context "when the account's currency is unknown" do
      let(:merchant_account_currency) { nil }

      it "falls back to the existing behaviour rather than guessing a currency" do
        expect(flow_of_funds.merchant_account_gross_amount).to be_nil
        expect(flow_of_funds.merchant_account_net_amount).to be_nil
      end
    end
  end
end
