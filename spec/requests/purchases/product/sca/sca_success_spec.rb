# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("Successful purchases from a product page with SCA (Strong Customer Authentication)", type: :system, js: true) do
  before do
    @creator = create(:named_user)
    @product = create(:product, user: @creator)
  end

  context "as a guest user" do
    it "allows to make a classic purchase" do
      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product)
      check_out(@product, credit_card: { number: "4000002500003155" }, sca: true)
    end

    it "allows to purchase a classic product via stripe connect account" do
      allow_any_instance_of(User).to receive(:check_merchant_account_is_linked).and_return(true)
      stripe_connect_account = create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1MeFbmKQKir5qdfM", user: @product.user)

      visit @product.long_url
      add_to_cart(@product)
      check_out(@product, credit_card: { number: "4000002500003155" }, sca: true)

      expect(Purchase.last.successful?).to be true
      expect(Purchase.last.stripe_transaction_id).to be_present
      expect(Purchase.last.merchant_account).to eq(stripe_connect_account)
    end
  end

  context "as a logged in user" do
    before do
      @user = create(:user)
      login_as @user
    end

    it "allows to purchase a classic product" do
      visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"
      add_to_cart(@product)
      check_out(@product, credit_card: { number: "4000002500003155" }, sca: true, logged_in_user: @user)
    end

    it "allows to purchase a classic product via stripe connect account" do
      allow_any_instance_of(User).to receive(:check_merchant_account_is_linked).and_return(true)
      stripe_connect_account = create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1MeFbmKQKir5qdfM", user: @product.user)

      visit @product.long_url
      add_to_cart(@product)
      check_out(@product, credit_card: { number: "4000002500003155" }, sca: true, logged_in_user: @user)

      expect(Purchase.last.successful?).to be true
      expect(Purchase.last.stripe_transaction_id).to be_present
      expect(Purchase.last.merchant_account).to eq(stripe_connect_account)
    end
  end
end
