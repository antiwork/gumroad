# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("Purchase from a product page with SCA (Strong Customer Authentication)", type: :system, js: true) do
  before do
    @creator = create(:named_user)
    @product = create(:product, user: @creator)
  end

  context "as a logged in user" do
    before do
      @user = create(:user)
      login_as @user
    end

    context "when SCA fails" do
      it "creates a failed purchase for a classic product" do
        visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"
        add_to_cart(@product)
        check_out(@product, logged_in_user: @user, credit_card: { number: "4000002500003155" }, sca: false, error: "We are unable to authenticate your payment method. Please choose a different payment method and try again.")
      end

      it "creates a failed purchase for a subscription product" do
        membership_product = create(:membership_product)
        visit "#{membership_product.user.subdomain_with_protocol}/l/#{membership_product.unique_permalink}"
        add_to_cart(membership_product, option: "Untitled")
        check_out(membership_product, logged_in_user: @user, credit_card: { number: "4000002500003155" }, sca: false, error: "We are unable to authenticate your payment method. Please choose a different payment method and try again.")
      end

      it "creates a failed purchase for a pre-order product" do
        product = create(:product_with_files, is_in_preorder_state: true)
        preorder_product = create(:preorder_link, link: product, release_at: 25.hours.from_now)
        visit "#{product.user.subdomain_with_protocol}/l/#{product.unique_permalink}"
        expect do
          add_to_cart(product)
          check_out(product, logged_in_user: @user, credit_card: { number: "4000002500003155" }, sca: false, error: "We are unable to authenticate your payment method. Please choose a different payment method and try again.")
        end.to change { preorder_product.preorders.authorization_failed.count }.by(1)
      end
    end
  end
end
