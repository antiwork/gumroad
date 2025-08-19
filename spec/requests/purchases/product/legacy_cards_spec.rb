# frozen_string_literal: true

require("spec_helper")
require "timeout"

# In March 2021 we migrated from Stripe's Charges API to Payment Intents API.
# Many customers have stored their credit cards on file using the old Charges API (via a credit card token).
# This spec ensures that those legacy credit cards keep working under the new Payment Intents API.
describe("Purchase using a saved card created under the old Charges API", type: :system, js: true) do
  before do
    @creator = create(:named_user)
    # We create a card via a CC token which is how things were done under the legacy Charges API
    legacy_credit_card = create(:credit_card, chargeable: build(:cc_token_chargeable, card: CardParamsSpecHelper.success))
    @user = create(:user, credit_card: legacy_credit_card)
    login_as @user
  end

  it "allows to purchase a classic product" do
    classic_product = create(:product, user: @creator)
    visit "#{classic_product.user.subdomain_with_protocol}/l/#{classic_product.unique_permalink}"
    add_to_cart(classic_product)
    check_out(classic_product, logged_in_user: @user)
  end

  it "allows to purchase a subscription product" do
    membership_product = create(:membership_product)
    visit "#{membership_product.user.subdomain_with_protocol}/l/#{membership_product.unique_permalink}"
    add_to_cart(membership_product, option: "Untitled")
    check_out(membership_product, logged_in_user: @user)

    travel_to 1.month.from_now

    expect do
      membership_product.subscriptions.last.charge!
    end.to change { membership_product.sales.successful.count }.by(1)
  end

  it "allows to pre-order a product" do
    product = create(:product_with_files, is_in_preorder_state: true)
    create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => product.product_files.first.external_id, "uid" => SecureRandom.uuid } }])
    preorder_product = create(:preorder_link, link: product, release_at: 25.hours.from_now)
    visit "#{product.user.subdomain_with_protocol}/l/#{product.unique_permalink}"

    add_to_cart(product)
    check_out(product, logged_in_user: @user)

    travel_to 25.hours.from_now

    index_model_records(Purchase)

    expect do
      Sidekiq::Testing.inline! do
        preorder_product.release!
      end
    end.to change { product.sales.successful.count }.by(1)
  end
end
