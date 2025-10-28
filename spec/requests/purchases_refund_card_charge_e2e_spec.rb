# frozen_string_literal: true

require "spec_helper"

# Configure Capybara to slow down tests for visibility
Capybara.default_max_wait_time = 5
# Use visible browser when running locally for easier debugging
Capybara.default_driver = if ENV["IN_DOCKER"] == "true"
                            :docker_headless_chrome
                          elsif ENV["SHOW_BROWSER"] == "true"
                            :chrome
                          else
                            :chrome_headless
                          end

describe "Refund Card Charge E2E", js: true, type: :system, sidekiq_inline: true do
  # Helper for refund flow tests - slower to read toasts
  def slow_step_for_refund(description, &block)
    puts "\n=== Step: #{description} ==="
    sleep 1.5  # Longer delay to see actions
    yield if block_given?
    sleep 2.0  # Longer delay to read toasts
  end

  let(:seller) { create(:named_seller) }
  let(:purchaser) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }

  let(:merchant_account) do
    MerchantAccount.create!(
      charge_processor_id: "stripe",
      charge_processor_merchant_id: "test_merchant_123",
      user_id: nil,
      json_data: { meta: { stripe_connect: "false" } }
    )
  end

  let!(:purchase) do
    p = Purchase.new(
      link: product,
      purchaser: purchaser,
      email: purchaser.email,
      full_name: purchaser.name,
      seller: seller,
      price_cents: 1000,
      total_transaction_cents: 1000,
      displayed_price_cents: 1000,
      stripe_transaction_id: "ch_test_#{SecureRandom.hex(8)}",
      purchase_state: "successful",
      succeeded_at: Time.current,
      merchant_account: merchant_account,
      charge_processor_id: "stripe",
      card_type: "visa",
      card_visual: "****4242",
      stripe_fingerprint: "fp_test_#{SecureRandom.hex(8)}",
      fee_cents: 100,
      processor_fee_cents: 100,
      gumroad_tax_cents: 0,
      tax_cents: 0,
      shipping_cents: 0,
      ip_address: "127.0.0.1",
      browser_guid: SecureRandom.uuid
    )
    p.save!(validate: false)
    p
  end

  let(:refund_credit_card) do
    card = CreditCard.new(
      stripe_customer_id: "cus_test_#{SecureRandom.hex(8)}",
      stripe_fingerprint: "card_test_#{SecureRandom.hex(8)}",
      card_type: "Visa",
      visual: "****4242",
      expiry_month: 12,
      expiry_year: 2025
    )
    card.save!(validate: false)
    card
  end

  before do
    # Mock Stripe API calls for charge
    allow(Stripe::Charge).to receive(:create).and_return(
      double("Stripe::Charge", status: "succeeded", id: "ch_test_123")
    )

    # Mock ChargeProcessor for refund processing
    charge_refund = double("ChargeRefund",
      id: "re_test_123",
      refund: double("Refund", id: "ref_test_123", status: "succeeded"),
      flow_of_funds: double("FlowOfFunds",
        issued_amount: double("Amount", cents: 1000, currency: "usd"),
        merchant_account_gross_amount: double("Amount", cents: 900, currency: "usd"),
        merchant_account_net_amount: double("Amount", cents: 800, currency: "usd"),
        to_h: { "issued_amount" => { "cents" => 1000 } }
      )
    )
    allow(ChargeProcessor).to receive(:refund!).and_return(charge_refund)

    # Index purchases for Elasticsearch
    index_model_records(Purchase)
  end

  describe "Refund flow with refund card" do
    describe "when seller has insufficient balance and refund card" do
      before do
        # Set seller balance to $5.00 (500 cents), need to refund $10.00 (1000 cents)
        # Create actual balance records instead of mocking
        seller.balances.destroy_all
        create(:balance, user: seller, amount_cents: 500)

        seller.update!(refund_credit_card: refund_credit_card)

        login_as seller
      end

      it "charges refund card and processes refund successfully" do
        # Verify Stripe will be called with correct parameters
        expect(Stripe::Charge).to receive(:create).with(
          hash_including(
            amount: 500, # $5.00 difference
            currency: "usd",
            customer: refund_credit_card.stripe_customer_id,
            source: refund_credit_card.stripe_fingerprint
          )
        )

        slow_step_for_refund("Navigate to customers page") do
          visit customers_path
        end

        slow_step_for_refund("Open customer drawer") do
          find(:table_row, { "Email" => purchaser.email }).click
        end

        slow_step_for_refund("Click Refund fully button") do
          # Find and interact with refund section within the product
          within_section product.name, section_element: :aside do
            within_section "Refund", section_element: :section do
              click_on "Refund fully"
            end
          end
        end

        slow_step_for_refund("Confirm refund in modal") do
          # Confirm in modal
          within_modal "Purchase refund" do
            click_on "Confirm refund"
          end
        end

        slow_step_for_refund("Verify success message") do
          # Verify success message
          expect(page).to have_alert(text: "Purchase successfully refunded.")
        end

        # Verify database state
        slow_step_for_refund("Verify database state") do
          purchase.reload
          expect(purchase.stripe_refunded?).to be true
          expect(purchase.refunds.count).to eq(1)
        end
      end
    end

    describe "when refund card charge fails" do
      before do
        # Create balance records
        seller.balances.destroy_all
        create(:balance, user: seller, amount_cents: 500)

        seller.update!(refund_credit_card: refund_credit_card)

        # Mock Stripe failure
        failed_charge = double("Stripe::Charge",
          status: "failed",
          failure_message: "Your card was declined."
        )
        allow(Stripe::Charge).to receive(:create).and_return(failed_charge)

        login_as seller
      end

      it "shows error message and does not process refund" do
        slow_step_for_refund("Navigate to customers page") do
          visit customers_path
        end

        slow_step_for_refund("Open customer drawer") do
          find(:table_row, { "Email" => purchaser.email }).click
        end

        slow_step_for_refund("Click Refund fully button") do
          within_section product.name, section_element: :aside do
            within_section "Refund", section_element: :section do
              click_on "Refund fully"
            end
          end
        end

        slow_step_for_refund("Confirm refund in modal") do
          within_modal "Purchase refund" do
            click_on "Confirm refund"
          end
        end

        slow_step_for_refund("Verify error message") do
          # Verify error is shown
          expect(page).to have_alert(text: /Unable to process refund|Your card was declined/i)
        end

        # Verify refund did not process
        slow_step_for_refund("Verify refund did not process") do
          purchase.reload
          expect(purchase.stripe_refunded?).to be false
          expect(purchase.refunds.count).to eq(0)
        end
      end
    end

    describe "when seller has sufficient balance" do
      before do
        # Set balance to cover full refund ($10.00)
        seller.balances.destroy_all
        create(:balance, user: seller, amount_cents: 1000)

        seller.update!(refund_credit_card: refund_credit_card)

        login_as seller
      end

      it "processes refund without charging card" do
        # Verify Stripe is NOT called
        expect(Stripe::Charge).not_to receive(:create)

        slow_step_for_refund("Navigate to customers page") do
          visit customers_path
        end

        slow_step_for_refund("Open customer drawer") do
          find(:table_row, { "Email" => purchaser.email }).click
        end

        slow_step_for_refund("Click Refund fully button") do
          within_section product.name, section_element: :aside do
            within_section "Refund", section_element: :section do
              click_on "Refund fully"
            end
          end
        end

        slow_step_for_refund("Confirm refund in modal") do
          within_modal "Purchase refund" do
            click_on "Confirm refund"
          end
        end

        slow_step_for_refund("Verify success message") do
          expect(page).to have_alert(text: "Purchase successfully refunded.")
        end

        slow_step_for_refund("Verify database state") do
          purchase.reload
          expect(purchase.stripe_refunded?).to be true
          expect(purchase.refunds.count).to eq(1)
        end
      end
    end

    describe "when seller has no refund card" do
      before do
        # Create balance records
        seller.balances.destroy_all
        create(:balance, user: seller, amount_cents: 500)
        # NO refund card set - seller.refund_credit_card is nil

        login_as seller
      end

      it "shows insufficient balance error" do
        slow_step_for_refund("Navigate to customers page") do
          visit customers_path
        end

        slow_step_for_refund("Open customer drawer") do
          find(:table_row, { "Email" => purchaser.email }).click
        end

        slow_step_for_refund("Click Refund fully button") do
          within_section product.name, section_element: :aside do
            within_section "Refund", section_element: :section do
              click_on "Refund fully"
            end
          end
        end

        slow_step_for_refund("Confirm refund in modal") do
          within_modal "Purchase refund" do
            click_on "Confirm refund"
          end
        end

        slow_step_for_refund("Verify error message") do
          # Verify error message about insufficient balance
          expect(page).to have_alert(text: /insufficient|refund card/i)
        end

        slow_step_for_refund("Verify refund did not process") do
          # Verify refund did not process
          purchase.reload
          expect(purchase.stripe_refunded?).to be false
          expect(purchase.refunds.count).to eq(0)
        end
      end
    end

    describe "when Stripe raises an error during charge" do
      before do
        # Create balance records
        seller.balances.destroy_all
        create(:balance, user: seller, amount_cents: 500)

        seller.update!(refund_credit_card: refund_credit_card)

        # Mock Stripe error
        allow(Stripe::Charge).to receive(:create).and_raise(
          Stripe::CardError.new("Your card has insufficient funds.", "card_declined")
        )

        login_as seller
      end

      it "handles error gracefully and shows error message" do
        slow_step_for_refund("Navigate to customers page") do
          visit customers_path
        end

        slow_step_for_refund("Open customer drawer") do
          find(:table_row, { "Email" => purchaser.email }).click
        end

        slow_step_for_refund("Click Refund fully button") do
          within_section product.name, section_element: :aside do
            within_section "Refund", section_element: :section do
              click_on "Refund fully"
            end
          end
        end

        slow_step_for_refund("Confirm refund in modal") do
          within_modal "Purchase refund" do
            click_on "Confirm refund"
          end
        end

        slow_step_for_refund("Verify error message") do
          # Verify error message is shown
          expect(page).to have_alert(text: /Stripe error|Unable to process/i)
        end

        slow_step_for_refund("Verify refund did not process") do
          # Verify refund did not process
          purchase.reload
          expect(purchase.stripe_refunded?).to be false
          expect(purchase.refunds.count).to eq(0)
        end
      end
    end

    describe "partial refund scenario" do
      before do
        # Seller has $2.00 balance, wants to refund $5.00 out of $10.00
        seller.balances.destroy_all
        create(:balance, user: seller, amount_cents: 200)

        seller.update!(refund_credit_card: refund_credit_card)

        login_as seller
      end

      it "charges card for difference and processes partial refund" do
        # Mock ChargeProcessor to return partial refund flow_of_funds
        partial_charge_refund = double("ChargeRefund",
          id: "re_test_partial",
          refund: double("Refund", id: "ref_test_partial", status: "succeeded"),
          flow_of_funds: double("FlowOfFunds",
            issued_amount: double("Amount", cents: 500, currency: "usd"),
            merchant_account_gross_amount: double("Amount", cents: 450, currency: "usd"),
            merchant_account_net_amount: double("Amount", cents: 400, currency: "usd"),
            to_h: { "issued_amount" => { "cents" => 500 } }
          )
        )
        allow(ChargeProcessor).to receive(:refund!).and_return(partial_charge_refund)

        # Verify Stripe will be called with $3.00 difference (500 - 200 = 300 cents)
        expect(Stripe::Charge).to receive(:create).with(
          hash_including(
            amount: 300,
            currency: "usd",
            customer: refund_credit_card.stripe_customer_id,
            source: refund_credit_card.stripe_fingerprint
          )
        )

        slow_step_for_refund("Navigate to customers page") do
          visit customers_path
        end

        slow_step_for_refund("Open customer drawer") do
          find(:table_row, { "Email" => purchaser.email }).click
        end

        slow_step_for_refund("Enter partial refund amount") do
          within_section product.name, section_element: :aside do
            within_section "Refund", section_element: :section do
              # Enter partial refund amount: $5.00
              fill_in "10", with: "5"
              click_on "Issue partial refund"
            end
          end
        end

        slow_step_for_refund("Confirm partial refund in modal") do
          within_modal "Purchase refund" do
            click_on "Confirm refund"
          end
        end

        slow_step_for_refund("Verify success message") do
          expect(page).to have_alert(text: "Purchase successfully refunded.")
        end

        # Verify partial refund state
        slow_step_for_refund("Verify partial refund state") do
          purchase.reload
          expect(purchase.stripe_partially_refunded?).to be true
          expect(purchase.stripe_refunded?).to be false
          expect(purchase.refunds.count).to eq(1)
          expect(purchase.amount_refundable_cents).to eq(500)
        end
      end
    end
  end
end

