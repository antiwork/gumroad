# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Coffee Edit", type: :system, js: true do
  let(:seller) { create(:user, :eligible_for_service_products, name: "Caffeine Addict") }
  let(:coffee) do
    create(
      :product,
      user: seller,
      name: "Coffee",
      description: "Buy me a coffee",
      native_type: Link::NATIVE_TYPE_COFFEE,
      purchase_disabled_at: Time.current
    )
  end

  include_context "with switching account to user as admin for seller"

  before { Feature.activate_user(:product_edit_react, seller) }

  it "allows editing coffee products" do
    visit edit_link_path(coffee.unique_permalink)

    suggested_amount1 = coffee.alive_variants.first

    find_field("Header", with: "Coffee").fill_in with: "Coffee product"
    find_field("Body", with: "Buy me a coffee").fill_in with: "Buy me a coffee product"
    find_field("Call to action", with: "donate_prompt").select "Support"
    expect(page).to have_field("URL", with: custom_domain_coffee_url(host: seller.subdomain), disabled: true)
    expect(page).to have_field("Suggested amount 1", with: 1)

    in_preview do
      expect(page).to have_link("Caffeine Addict")
      expect(page).to have_selector("h1", text: "Coffee product")
      expect(page).to have_selector("h3", text: "Buy me a coffee product")
      expect(page).to have_field("Price", with: "1")
      expect(page).to have_link("Support")
    end

    click_on "Add amount"
    fill_in "Suggested amount 2", with: 2
    click_on "Delete", match: :first

    in_preview { expect(page).to have_field("Price", with: "2") }

    click_on "Add amount"
    fill_in "Suggested amount 2", with: 4

    select "Tip", from: "Call to action"

    in_preview do
      expect(page).to have_radio_button("$2")
      expect(page).to have_radio_button("$4")
      expect(page).to have_radio_button("Other", checked: true)
      expect(page).to have_field("Price")
      expect(page).to have_link("Tip")
    end

    click_on "Save changes"
    expect(page).to have_alert(text: "Changes saved!")

    refresh
    in_preview { expect(page).to have_radio_button("Other", checked: true) }

    expect(suggested_amount1.reload).to be_deleted
    coffee.reload
    expect(coffee.name).to eq("Coffee product")
    expect(coffee.description).to eq("Buy me a coffee product")
    expect(coffee.custom_button_text_option).to eq("tip_prompt")
    suggested_amount2 = coffee.alive_variants.first
    expect(suggested_amount2.name).to eq("")
    expect(suggested_amount2.price_difference_cents).to eq(200)
    suggested_amount3 = coffee.alive_variants.second
    expect(suggested_amount3.name).to eq("")
    expect(suggested_amount3.price_difference_cents).to eq(400)
  end
end
