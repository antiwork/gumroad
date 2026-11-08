# frozen_string_literal: true

require "spec_helper"

# Follows the buyer link from the seller's sale notification through the real routes. An unseen download page lets
# its first visitor in without confirming an email, so the link must not skip the receipt's buyer email check.
describe "Buyer link in the seller's sale notification", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller:, email: "buyer@example.com") }
  let(:url_redirect) { purchase.url_redirect }

  before { purchase.create_url_redirect! }

  def buyer_link
    html = ContactingCreatorMailer.notify(purchase.id).body.decoded
    link = Nokogiri::HTML(html).at_xpath("//h4[starts-with(normalize-space(), \"Buyer's\")]/ancestor::tr[1]//a")
    expect(link).to be_present
    link["href"]
  end

  def expect_download_page_unopened
    url_redirect.reload
    expect(url_redirect.has_been_seen).to be(false)
    expect(url_redirect.uses).to eq(0)
    expect(response.body).not_to include(url_redirect.token)
  end

  it "asks a visitor for the buyer's email before showing anything, even while the download page is unseen" do
    expect(url_redirect.has_been_seen).to be(false)

    get buyer_link

    expect(response).to redirect_to(confirm_receipt_email_purchase_path(purchase.external_id))
    expect_download_page_unopened
  end

  it "asks the signed-in seller for the buyer's email too" do
    sign_in seller

    get buyer_link

    expect(response).to redirect_to(confirm_receipt_email_purchase_path(purchase.external_id))
    expect_download_page_unopened
  end

  it "turns away a wrong email" do
    get buyer_link, params: { email: "someone-else@example.com" }

    expect(response).to redirect_to(confirm_receipt_email_purchase_path(purchase.external_id))
    expect(flash[:alert]).to eq("Wrong email. Please try again.")
    expect_download_page_unopened
  end

  it "shows the buyer's receipt with their download link once the buyer's email is given" do
    get buyer_link, params: { email: "Buyer@example.com " }

    expect(response).to be_successful
    expect(response.body).to include(url_redirect.download_page_url)
    url_redirect.reload
    expect(url_redirect.has_been_seen).to be(false)
    expect(url_redirect.uses).to eq(0)
  end
end
