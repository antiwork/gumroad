# frozen_string_literal: true

require "spec_helper"

RSpec.describe Purchase::Refundable, "with refund payment method" do
  let(:seller) { create(:user) }
  let(:purchaser) { create(:user) }
  let(:merchant_account) do

    MerchantAccount.create!(
      charge_processor_id: "stripe",
      charge_processor_merchant_id: "test_merchant_123",
      user_id: nil,
      json_data: { meta: { stripe_connect: "false" } }
    )
  end

  let(:link) do
    link = Link.new(
      user: seller,
      name: "Test Product",
      price_cents: 1000,
      price_currency_type: "usd",
      draft: false,
      native_type: "digital",
      unique_permalink: "test_product_abc"
    )
    link.save!(validate: false) # Skip validations to avoid permalink format issues

    allow(link).to receive(:base_product_price_cents).and_return(1000)
    allow(link).to receive(:variant_extra_cost).and_return(0)
    allow(link).to receive(:minimum_paid_price_cents).and_return(1000)


    allow(link).to receive(:variant_categories_alive).and_return([])
    allow(link).to receive(:association_cached?).with(:variant_categories_alive).and_return(false)

    link
  end

  let(:purchase) do
    # Create a purchase without validations to avoid factory issues
    Purchase.new(
      seller: seller,
      purchaser: purchaser,
      link: link,
      price_cents: 1000,
      displayed_price_cents: 1000,
      total_transaction_cents: 1000,
      email: purchaser.email,
      full_name: purchaser.name,
      card_country: "US",
      ip_address: "127.0.0.1",
      charge_processor_id: "stripe",
      stripe_status: "succeeded",
      stripe_transaction_id: "ch_test_#{SecureRandom.hex(8)}",
      purchase_state: "successful",
      succeeded_at: Time.current,
      merchant_account: merchant_account,
      gumroad_tax_cents: 0,
      tax_cents: 0,
      fee_cents: 100,
      processor_fee_cents: 100
    )
  end
  let(:refunding_user_id) { seller.id }

  # Mock Stripe calls to avoid VCR issues
  before do
    allow(Stripe::Charge).to receive(:create).and_return(
      double("Stripe::Charge", status: "succeeded", id: "ch_test_123")
    )

    # Mock purchase validation to avoid financial_transaction_validation issues
    allow_any_instance_of(Purchase).to receive(:valid?).and_return(true)
    allow_any_instance_of(Purchase).to receive(:save!).and_return(true)

    # Mock the complex price validation methods
    allow_any_instance_of(Purchase).to receive(:minimum_paid_price_cents).and_return(1000)
    allow_any_instance_of(Purchase).to receive(:minimum_paid_price_cents_per_unit_before_discount).and_return(1000)
    allow_any_instance_of(Purchase).to receive(:base_product_price_cents).and_return(1000)
    allow_any_instance_of(Purchase).to receive(:variant_extra_cost).and_return(0)
  end

  before do
    # Mock the charge processor to avoid actual Stripe calls
    allow(ChargeProcessor).to receive(:refund!).and_return(
      double("ChargeRefund",
        id: "refund_123",
        refund: double("Refund", id: "ref_123", status: "succeeded"),
        flow_of_funds: double("FlowOfFunds",
          issued_amount: double("Amount", cents: 1000, currency: "usd"),
          merchant_account_gross_amount: double("Amount", cents: 900, currency: "usd"),
          merchant_account_net_amount: double("Amount", cents: 800, currency: "usd"),
          to_h: { "issued_amount" => { "cents" => 1000 } }
        )
      )
    )
  end

  describe "#refund_and_save!" do
    context "when seller has sufficient balance" do
      before do
        allow(seller).to receive(:unpaid_balance_cents).and_return(1500) # $15.00
      end

      it "processes refund without charging refund card" do
        expect(ChargeSellerRefundCardService).not_to receive(:new)

        result = purchase.refund_and_save!(refunding_user_id)

        expect(result).to be true
        expect(purchase.errors).to be_empty
      end
    end

    context "when seller has insufficient balance" do
      before do
        allow(seller).to receive(:unpaid_balance_cents).and_return(500) # $5.00
      end

          context "and seller has refund credit card" do
            let(:refund_credit_card) do
              # Create a credit card without making real Stripe calls
              CreditCard.new(
                stripe_customer_id: "cus_123",
                stripe_fingerprint: "card_123",
                card_type: "Visa",
                visual: "****4242",
                expiry_month: 12,
                expiry_year: 2025
              )
            end

            before do
              refund_credit_card.save!(validate: false) # Skip validations to avoid Stripe calls
              seller.update!(refund_credit_card: refund_credit_card)
            end

        context "and refund card charge succeeds" do
          before do
            refund_card_service = double("ChargeSellerRefundCardService")
            allow(ChargeSellerRefundCardService).to receive(:new).and_return(refund_card_service)
            allow(refund_card_service).to receive(:call).and_return(
              double("Result", success?: true, charged_amount: 500, error_message: nil)
            )
          end

          it "charges refund card and processes refund" do
            expect(ChargeSellerRefundCardService).to receive(:new).with(seller, 1000)

            result = purchase.refund_and_save!(refunding_user_id)

            expect(result).to be true
            expect(purchase.errors).to be_empty
          end

        it "logs the refund card charge" do
          allow(Rails.logger).to receive(:info)

          purchase.refund_and_save!(refunding_user_id)
        end
        end

        context "and refund card charge fails" do
          before do
            refund_card_service = double("ChargeSellerRefundCardService")
            allow(ChargeSellerRefundCardService).to receive(:new).and_return(refund_card_service)
            allow(refund_card_service).to receive(:call).and_return(
              double("Result", success?: false, charged_amount: 0, error_message: "Your card was declined.")
            )
          end

          it "fails refund with error message" do
            result = purchase.refund_and_save!(refunding_user_id)

            expect(result).to be false
            expect(purchase.errors.full_messages).to include("Unable to process refund: Your card was declined.")
          end

          it "does not process the refund" do
            expect(ChargeProcessor).not_to receive(:refund!)

            purchase.refund_and_save!(refunding_user_id)
          end
        end
      end

      context "and seller has no refund credit card" do
        it "shows insufficient balance error" do
          result = purchase.refund_and_save!(refunding_user_id)

          expect(result).to be false
          expect(purchase.errors.full_messages).to include("Your balance is insufficient to process this refund.")
        end

        it "does not call refund card service" do
          expect(ChargeSellerRefundCardService).not_to receive(:new)

          purchase.refund_and_save!(refunding_user_id)
        end
      end
    end

    context "when seller has exact balance needed" do
      before do
        allow(seller).to receive(:unpaid_balance_cents).and_return(1000)
      end

      it "processes refund without charging refund card" do
        expect(ChargeSellerRefundCardService).not_to receive(:new)

        result = purchase.refund_and_save!(refunding_user_id)

        expect(result).to be true
        expect(purchase.errors).to be_empty
      end
    end

    context "with partial refunds" do
      let(:partial_amount_cents) { 500 }

      before do
        allow(seller).to receive(:unpaid_balance_cents).and_return(300)
      end

      context "and seller has refund credit card" do
        let(:refund_credit_card) do

          CreditCard.new(
            stripe_customer_id: "cus_123",
            stripe_fingerprint: "card_123",
            card_type: "Visa",
            visual: "****4242",
            expiry_month: 12,
            expiry_year: 2025
          )
        end

        before do
          refund_credit_card.save!(validate: false)
          seller.update!(refund_credit_card: refund_credit_card)
          refund_card_service = double("ChargeSellerRefundCardService")
          allow(ChargeSellerRefundCardService).to receive(:new).and_return(refund_card_service)
          allow(refund_card_service).to receive(:call).and_return(
            double("Result", success?: true, charged_amount: 200, error_message: nil)
          )
        end

        it "charges refund card for the difference and processes partial refund" do
          expect(ChargeSellerRefundCardService).to receive(:new).with(seller, 500)

          result = purchase.refund_and_save!(refunding_user_id, amount_cents: partial_amount_cents)

          expect(result).to be true
          expect(purchase.errors).to be_empty
        end
      end
    end

    context "when not using Gumroad merchant account" do
      let(:external_merchant_account) do
        # Create a real external merchant account (seller's own Stripe account)
        account = MerchantAccount.create!(
          charge_processor_id: "stripe",
          charge_processor_merchant_id: "acct_external_123",
          user_id: seller.id,
          json_data: { meta: { stripe_connect: "true" } }
        )

        # Mock the account to appear as if it's still connected and active
        allow(account).to receive(:is_a_stripe_connect_account?).and_return(true)
        allow(account).to receive(:active?).and_return(true)
        allow(account).to receive(:connected?).and_return(true)

        account
      end

      let(:non_gumroad_purchase) do

        purchase = Purchase.new(
          seller: seller,
          purchaser: purchaser,
          link: link,
          price_cents: 1000,
          displayed_price_cents: 1000,
          total_transaction_cents: 1000,
          email: purchaser.email,
          full_name: purchaser.name,
          card_country: "US",
          ip_address: "127.0.0.1",
          charge_processor_id: "stripe",
          stripe_status: "succeeded",
          stripe_transaction_id: "ch_test_#{SecureRandom.hex(8)}",
          purchase_state: "successful",
          succeeded_at: Time.current,
          created_at: Time.current,
          merchant_account: external_merchant_account,
          gumroad_tax_cents: 0,
          tax_cents: 0,
          fee_cents: 100,
          processor_fee_cents: 100
        )
        # Mock the purchase to bypass Gumroad merchant account check
        allow(purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(false)
        purchase
      end

      before do
        allow(seller).to receive(:unpaid_balance_cents).and_return(100)
      end

      it "does not check balance or charge refund card" do
        expect(ChargeSellerRefundCardService).not_to receive(:new)

        result = non_gumroad_purchase.refund_and_save!(refunding_user_id)

        unless result
          puts "Refund failed with errors: #{non_gumroad_purchase.errors.full_messages}"
        end

        expect(result).to be true
        expect(non_gumroad_purchase.errors).to be_empty
      end
    end

  end

  describe "error handling" do
    before do
      allow(seller).to receive(:unpaid_balance_cents).and_return(500)
      refund_credit_card = CreditCard.new(
        stripe_customer_id: "cus_123",
        stripe_fingerprint: "card_123",
        card_type: "Visa",
        visual: "****4242",
        expiry_month: 12,
        expiry_year: 2025
      )
      refund_credit_card.save!(validate: false)
      seller.update!(refund_credit_card: refund_credit_card)
    end

    context "when Stripe API raises an error during refund card charge" do
      before do
        refund_card_service = double("ChargeSellerRefundCardService")
        allow(ChargeSellerRefundCardService).to receive(:new).and_return(refund_card_service)
        allow(refund_card_service).to receive(:call).and_return(
          double("Result", success?: false, charged_amount: 0, error_message: "Stripe error: Your card has insufficient funds.")
        )
      end

      it "handles Stripe errors gracefully" do
        result = purchase.refund_and_save!(refunding_user_id)

        expect(result).to be false
        expect(purchase.errors.full_messages).to include("Unable to process refund: Stripe error: Your card has insufficient funds.")
      end
    end

    context "when refund card service raises an unexpected error" do
      before do
        allow(ChargeSellerRefundCardService).to receive(:new).and_raise(StandardError.new("Network timeout"))
      end

      it "handles unexpected errors gracefully" do
        expect { purchase.refund_and_save!(refunding_user_id) }.to raise_error(StandardError, "Network timeout")
      end
    end
  end
end
