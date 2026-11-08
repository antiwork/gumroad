# frozen_string_literal: true

require "spec_helper"

describe "Shared charge receipt", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:named_seller) }
  let(:email) { "buyer@example.com" }
  let(:purchase_one) { create(:purchase, link: create(:product, user: seller, name: "Book One"), seller:, email:) }
  let(:purchase_two) { create(:purchase, link: create(:product, user: seller, name: "Upsell Two"), seller:, email:) }
  let(:charge) { create(:charge, purchases: [purchase_one, purchase_two], seller:) }

  before do
    purchase_one.create_url_redirect!
    purchase_two.create_url_redirect!
    charge.order.purchases << purchase_one << purchase_two
  end

  it "asks for the buyer's email before showing anything" do
    get receipt_charge_url(charge.external_id)

    expect(response).to redirect_to(confirm_receipt_email_charge_url(charge.external_id))
  end

  it "asks the signed-in seller for the buyer's email too" do
    sign_in seller

    get receipt_charge_url(charge.external_id)

    expect(response).to redirect_to(confirm_receipt_email_charge_url(charge.external_id))
  end

  it "opens for the signed-in buyer without the email" do
    buyer = create(:user)
    [purchase_one, purchase_two].each { _1.update!(purchaser: buyer) }
    sign_in buyer

    get receipt_charge_url(charge.external_id)

    expect(response).to be_successful
    expect(response.body).to include("Book One", "Upsell Two")
  end

  it "asks another signed-in user for the buyer's email" do
    [purchase_one, purchase_two].each { _1.update!(purchaser: create(:user)) }
    sign_in create(:user)

    get receipt_charge_url(charge.external_id)

    expect(response).to redirect_to(confirm_receipt_email_charge_url(charge.external_id))
  end

  it "turns away a wrong email" do
    get receipt_charge_url(charge.external_id), params: { email: "other@example.com" }

    expect(response).to redirect_to(confirm_receipt_email_charge_url(charge.external_id))
    expect(flash[:alert]).to eq("Wrong email. Please try again.")
  end

  it "shows every item of the charge once the buyer's email is given" do
    get receipt_charge_url(charge.external_id), params: { email: " Buyer@example.com " }

    expect(response).to be_successful
    expect(response.body).to include("Book One", "Upsell Two")
    expect(response.body).to include(purchase_one.url_redirect.download_page_url, purchase_two.url_redirect.download_page_url)
  end

  it "shows the confirm page" do
    get confirm_receipt_email_charge_url(charge.external_id)

    expect(response).to be_successful
    expect(response.body).to include("Confirm your email address")
  end

  it "404s for an unknown charge" do
    get receipt_charge_url("nope")
    expect(response).to have_http_status(:not_found)
  end

  it "404s when the buyer emails differ" do
    purchase_two.update_column(:email, "someone-else@example.com")

    get receipt_charge_url(charge.external_id), params: { email: email }

    expect(response).to have_http_status(:not_found)
  end

  it "404s for a single-purchase charge" do
    lone = create(:purchase, link: create(:product, user: seller), seller:, email:)
    single = create(:charge, purchases: [lone], seller:)

    get receipt_charge_url(single.external_id), params: { email: email }

    expect(response).to have_http_status(:not_found)
  end
end
