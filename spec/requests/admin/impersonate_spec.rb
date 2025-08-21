# frozen_string_literal: true

require "spec_helper"

describe "Impersonate", type: :system, js: true do
  let(:admin) { create(:admin_user, name: "Gumlord") }
  let(:seller) do
    user = create(:named_seller)
    create(:merchant_account_stripe, user:)
    user
  end

  before do
    login_as(admin)
  end

  it "impersonates and unimpersonates a seller using email" do
    impersonate_and_verify(seller, seller.email)
  end

  it "impersonates and unimpersonates a seller using username" do
    impersonate_and_verify(seller, seller.username)
  end

  it "impersonates and unimpersonates a seller using Stripe account ID" do
    impersonate_and_verify(seller, seller.merchant_accounts.sole.charge_processor_merchant_id)
  end

  def impersonate_and_verify(seller, identifier)
    visit "/admin"
    fill_in "Enter user email, username, or Stripe account ID", with: identifier
    click_on "Impersonate user"
    wait_for_ajax

    visit settings_main_path
    wait_for_ajax
    within_section "User details", section_element: :section do
      expect(page).to have_input_labelled "Email", with: seller.email
    end

    within "nav[aria-label='Main']" do
      toggle_disclosure(seller.display_name)
      click_on "Unbecome"
      wait_for_ajax
      expect(page.current_path).to eq(admin_path)
    end
  end
end
