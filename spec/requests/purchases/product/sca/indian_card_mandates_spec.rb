# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("Successful purchases from a product page with SCA and mandate creation for Indian cards", type: :system, js: true) do
  let(:creator) { create(:named_user) }
  let(:product) { create(:product, user: creator) }
  let(:membership_product) { create(:membership_product_with_preset_tiered_pricing, user: creator) }
  let(:free_trial_membership_product) { create(:membership_product_with_preset_tiered_pricing, :with_free_trial_enabled, user: creator) }
  let(:preorder_product) { create(:preorder_link, link: create(:product, is_in_preorder_state: true)).link }

  it "allows making a regular product purchase and does not set up a mandate on Stripe" do
    visit product.long_url
    add_to_cart(product)

    check_out(product, credit_card: { number: "4000003560000123" }, sca: true)

    purchase = Purchase.last
    expect(purchase.successful?).to be true
    expect(purchase.stripe_transaction_id).to be_present
    expect(purchase.processor_payment_intent_id).to be_present
    expect(purchase.processor_payment_intent).to be_present
    expect(purchase.credit_card).to be nil

    stripe_payment_intent = Stripe::PaymentIntent.retrieve(purchase.processor_payment_intent_id)
    stripe_charge = Stripe::Charge.retrieve(stripe_payment_intent.latest_charge)
    expect(stripe_charge.payment_method_details.card.mandate).to be nil
  end

  it "allows making a membership purchase and creates a mandate on Stripe for future off-session charges" do
    visit membership_product.long_url
    add_to_cart(membership_product, option: "Second Tier")

    check_out(membership_product, credit_card: { number: "4000003560000123" }, sca: true)

    purchase = Purchase.last
    expect(purchase.successful?).to be true
    expect(purchase.stripe_transaction_id).to be_present
    expect(purchase.processor_payment_intent_id).to be_present
    expect(purchase.processor_payment_intent).to be_present
    expect(purchase.credit_card.stripe_payment_intent_id).to be_present

    stripe_payment_intent = Stripe::PaymentIntent.retrieve(purchase.credit_card.stripe_payment_intent_id)
    stripe_charge = Stripe::Charge.retrieve(stripe_payment_intent.latest_charge)
    expect(stripe_charge.payment_method_details.card.mandate).to be_present
  end

  it "allows making a membership purchase and creates a mandate for future off-session charges with a card that cancels the mandate" do
    visit membership_product.long_url
    add_to_cart(membership_product, option: "Second Tier")

    check_out(membership_product, credit_card: { number: "4000003560000263" }, sca: true)

    purchase = Purchase.last
    expect(purchase.successful?).to be true
    expect(purchase.stripe_transaction_id).to be_present
    expect(purchase.processor_payment_intent_id).to be_present
    expect(purchase.processor_payment_intent).to be_present
    expect(purchase.credit_card.stripe_payment_intent_id).to be_present

    stripe_payment_intent = Stripe::PaymentIntent.retrieve(purchase.credit_card.stripe_payment_intent_id)
    stripe_charge = Stripe::Charge.retrieve(stripe_payment_intent.latest_charge)
    expect(stripe_charge.payment_method_details.card.mandate).to be_present
  end

  it "allows making a free-trial membership purchase and creates a mandate on Stripe for future off-session charges" do
    visit free_trial_membership_product.long_url
    add_to_cart(free_trial_membership_product, option: "Second Tier")

    check_out(free_trial_membership_product, credit_card: { number: "4000003560000123" }, sca: true)

    purchase = Purchase.last
    expect(purchase.not_charged?).to be true
    expect(purchase.stripe_transaction_id).not_to be_present
    expect(purchase.processor_setup_intent_id).to be_present
    expect(purchase.credit_card.stripe_setup_intent_id).to be_present
    expect(Stripe::SetupIntent.retrieve(purchase.credit_card.stripe_setup_intent_id).mandate).to be_present
  end

  it "allows making a pre-order purchase and creates a mandate on Stripe for future off-session charges" do
    preorder_product = create(:product, is_in_preorder_state: true)
    create(:preorder_link, link: preorder_product)
    visit "/l/#{preorder_product.unique_permalink}"

    add_to_cart(preorder_product)
    check_out(preorder_product, credit_card: { number: "4000003560000123" }, sca: true)

    expect(page).to have_content("We sent a receipt to test@gumroad.com")
    expect(page).to have_text("$1")

    purchase = Purchase.last
    expect(purchase.preorder_authorization_successful?).to be true
    expect(purchase.stripe_transaction_id).not_to be_present
    expect(purchase.processor_setup_intent_id).to be_present
    expect(purchase.credit_card.stripe_setup_intent_id).to be_present
    expect(Stripe::SetupIntent.retrieve(purchase.credit_card.stripe_setup_intent_id).mandate).to be_present
  end

  context "via stripe connect" do
    before { allow_any_instance_of(User).to receive(:check_merchant_account_is_linked).and_return(true) }
    let!(:stripe_connect_account) { create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1MeFbmKQKir5qdfM", user: creator) }

    it "allows making a regular product purchase and does not set up a mandate on Stripe" do
      visit product.long_url
      add_to_cart(product)

      check_out(product, credit_card: { number: "4000003560000123" }, sca: true)

      purchase = Purchase.last
      expect(purchase.successful?).to be true
      expect(purchase.stripe_transaction_id).to be_present
      expect(purchase.processor_payment_intent_id).to be_present
      expect(purchase.processor_payment_intent).to be_present
      expect(purchase.credit_card).to be nil
      expect(purchase.merchant_account).to eq(stripe_connect_account)

      stripe_payment_intent = Stripe::PaymentIntent.retrieve(purchase.processor_payment_intent_id,
                                                             { stripe_account: stripe_connect_account.charge_processor_merchant_id })
      stripe_charge = Stripe::Charge.retrieve(stripe_payment_intent.latest_charge,
                                              { stripe_account: stripe_connect_account.charge_processor_merchant_id })
      expect(stripe_charge.payment_method_details.card.mandate).to be nil
    end

    it "allows making a membership purchase and sets up the mandate properly" do
      visit membership_product.long_url
      add_to_cart(membership_product, option: "Second Tier")

      check_out(membership_product, credit_card: { number: "4000003560000123" }, sca: true)

      purchase = Purchase.last
      expect(purchase.successful?).to be true
      expect(purchase.stripe_transaction_id).to be_present
      expect(purchase.processor_payment_intent_id).to be_present
      expect(purchase.processor_payment_intent).to be_present
      expect(purchase.credit_card.stripe_payment_intent_id).to be_present
      expect(purchase.merchant_account).to eq(stripe_connect_account)

      stripe_payment_intent = Stripe::PaymentIntent.retrieve(purchase.credit_card.stripe_payment_intent_id,
                                                             { stripe_account: stripe_connect_account.charge_processor_merchant_id })
      stripe_charge = Stripe::Charge.retrieve(stripe_payment_intent.latest_charge,
                                              { stripe_account: stripe_connect_account.charge_processor_merchant_id })
      expect(stripe_charge.payment_method_details.card.mandate).to be_present
    end
  end
end
