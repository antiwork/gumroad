# frozen_string_literal: true

require "spec_helper"

describe "Shared charge receipt", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:named_seller) }
  let(:email) { "buyer@example.com" }
  let(:purchase_one) { create(:purchase, link: create(:product, user: seller, name: "Book One"), seller:, email:) }
  let(:purchase_two) { create(:purchase, link: create(:product, user: seller, name: "Upsell Two"), seller:, email:) }
  let(:charge) { create(:charge, purchases: [purchase_one, purchase_two], seller:) }
  let(:token) { charge.secure_external_id(scope: Charge::SHARED_RECEIPT_SCOPE) }

  before do
    purchase_one.create_url_redirect!
    purchase_two.create_url_redirect!
    charge.order.purchases << purchase_one << purchase_two
  end

  def expect_buyer_verification_page
    expect(response).to be_successful
    expect(response.body).to include("View your receipt", "Email me my receipt")
    expect(response.body).not_to include("Book One", "Upsell Two")
  end

  def expect_shared_receipt
    expect(response).to be_successful
    expect(response.body).to include("Book One", "Upsell Two")
    expect(response.body).to include(purchase_one.url_redirect.download_page_url, purchase_two.url_redirect.download_page_url)
  end

  it "opens through the tokened link from the buyer's receipt email" do
    get receipt_charge_url(charge.external_id, token:)

    expect_shared_receipt
    expect(response.headers["X-Robots-Tag"]).to eq("noindex")
  end

  it "asks for verification on the bare link" do
    get receipt_charge_url(charge.external_id)

    expect_buyer_verification_page
  end

  it "does not open for someone who only knows the buyer's email" do
    get receipt_charge_url(charge.external_id), params: { email: }

    expect_buyer_verification_page
  end

  it "does not open with another charge's token" do
    other_purchases = 2.times.map { create(:purchase, link: create(:product, user: seller), seller:, email:) }
    other_charge = create(:charge, purchases: other_purchases, seller:)

    get receipt_charge_url(charge.external_id, token: other_charge.secure_external_id(scope: Charge::SHARED_RECEIPT_SCOPE))

    expect_buyer_verification_page
  end

  it "does not open with this charge's token for another scope" do
    get receipt_charge_url(charge.external_id, token: charge.secure_external_id(scope: "confirm"))

    expect_buyer_verification_page
  end

  it "does not open for the signed-in seller" do
    sign_in seller

    get receipt_charge_url(charge.external_id)

    expect_buyer_verification_page
  end

  it "opens for the signed-in buyer who made every purchase" do
    buyer = create(:user)
    [purchase_one, purchase_two].each { _1.update!(purchaser: buyer) }
    sign_in buyer

    get receipt_charge_url(charge.external_id)

    expect_shared_receipt
  end

  it "does not open for a signed-in user who made only one of the purchases" do
    buyer = create(:user)
    purchase_one.update!(purchaser: buyer)
    sign_in buyer

    get receipt_charge_url(charge.external_id)

    expect_buyer_verification_page
  end

  it "does not open for another signed-in user" do
    [purchase_one, purchase_two].each { _1.update!(purchaser: create(:user)) }
    sign_in create(:user)

    get receipt_charge_url(charge.external_id)

    expect_buyer_verification_page
  end

  it "opens for a team member" do
    sign_in create(:user, is_team_member: true)

    get receipt_charge_url(charge.external_id)

    expect_shared_receipt
  end

  it "mails the receipt to the buyer's address on request without showing it" do
    expect do
      post resend_receipt_charge_url(charge.external_id)
    end.to change { SendPurchaseReceiptJob.jobs.size }.by(1)

    expect(SendPurchaseReceiptJob.jobs.last["args"]).to eq([purchase_one.id, true])
    expect(response).to redirect_to(receipt_charge_path(charge.external_id))
    expect(flash[:notice]).to eq("Receipt sent to the email used for this order.")
    expect(flash[:notice]).not_to include(email)
  end

  it "404s for an unknown charge" do
    get receipt_charge_url("nope")
    expect(response).to have_http_status(:not_found)
  end

  it "404s when the buyer emails differ, even with a valid token" do
    purchase_two.update_column(:email, "someone-else@example.com")

    get receipt_charge_url(charge.external_id, token:)

    expect(response).to have_http_status(:not_found)
  end

  it "404s for a single-purchase charge" do
    lone = create(:purchase, link: create(:product, user: seller), seller:, email:)
    single = create(:charge, purchases: [lone], seller:)

    get receipt_charge_url(single.external_id, token: single.secure_external_id(scope: Charge::SHARED_RECEIPT_SCOPE))

    expect(response).to have_http_status(:not_found)
  end

  it "does not mail a receipt for a charge without a shared receipt" do
    purchase_two.update_column(:email, "someone-else@example.com")

    post resend_receipt_charge_url(charge.external_id)

    expect(response).to have_http_status(:not_found)
    expect(SendPurchaseReceiptJob.jobs.size).to eq(0)
  end
end
