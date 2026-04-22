# frozen_string_literal: true

require "spec_helper"

describe "ProductCustomDomainScenario", type: :system, js: true do
  let(:product) { create(:product) }
  let(:custom_domain) { create(:custom_domain, domain: "test-custom-domain.gumroad.com", user: nil, product:) }
  let(:port) { Capybara.current_session.server.port }

  before do
    allow(Resolv::DNS).to receive_message_chain(:new, :getresources).and_return([double(name: "domains.gumroad.com")])
    Link.__elasticsearch__.create_index!(force: true)
    product.__elasticsearch__.index_document
    Link.__elasticsearch__.refresh_index!
  end

  it "successfully purchases the linked product" do
    visit "http://#{custom_domain.domain}:#{port}/"
    click_on "I want this!"
    check_out(product)
    expect(product.sales.successful.count).to eq(1)
  end

  context "when the URL includes product permalink" do
    it "successfully purchases the linked product" do
      visit "http://#{custom_domain.domain}:#{port}/l/#{product.unique_permalink}"
      click_on "I want this!"
      check_out(product)
      expect(product.sales.successful.count).to eq(1)
    end
  end

  context "when there is a discount code" do
    let(:product) { create(:product, price_cents: 600) }
    let(:offer_code) { create(:percentage_offer_code, products: [product], code: "LAUNCH", amount_percentage: 50) }

    it "applies the discount code when the URL contains only the discount code" do
      visit "http://#{custom_domain.domain}:#{port}/#{offer_code.code}"
      expect(page).to have_text("50% off will be applied at checkout (Code LAUNCH)")
      click_on "I want this!"
      check_out(product)
      expect(product.sales.successful.count).to eq(1)
    end

    it "applies the discount code when the URL contains both the discount code and the product" do
      visit "http://#{custom_domain.domain}:#{port}/l/#{product.unique_permalink}/#{offer_code.code}"
      expect(page).to have_text("50% off will be applied at checkout (Code LAUNCH)")
      click_on "I want this!"
      check_out(product)
      expect(product.sales.successful.count).to eq(1)
    end
  end

  context "when buyer is logged in" do
    let(:buyer) { create(:user) }
    before do
      login_as buyer
    end

    it "autofills the buyer's email address and purchases the product" do
      visit "http://#{custom_domain.domain}:#{port}/"
      click_on "I want this!"
      expect(page).to have_field("Email address", with: buyer.email, disabled: true)
      check_out(product, logged_in_user: buyer)
      expect(product.sales.successful.count).to eq(1)
    end
  end
end
