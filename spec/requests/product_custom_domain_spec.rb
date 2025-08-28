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
