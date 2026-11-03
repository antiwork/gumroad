# frozen_string_literal: true

require "spec_helper"

describe "Partner API sellers", type: :request do
  let(:partner_application) { create(:oauth_application, owner: create(:user), name: "Example App", is_partner: true, confidential: true, scopes: "partner_api") }
  let(:seller) { create(:user) }
  let(:seller_token) { create("doorkeeper/access_token", application: partner_application, resource_owner_id: seller.id, scopes: "partner_api") }

  before do
    host! "test.gumroad.com"
  end

  def link_seller(token, external_user_id: "ext-1")
    post "/api/v2/partner/sellers", params: { external_user_id: }.to_json, headers: { "CONTENT_TYPE" => "application/json", "AUTHORIZATION" => "Bearer #{token.token}" }
  end

  it "links the seller who authorized the partner, without a Migration Date" do
    link_seller(seller_token)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("success" => true, "external_user_id" => "ext-1")
    expect(partner_application.partner_sellers.sole).to have_attributes(user: seller, external_user_id: "ext-1", migrated_at: nil)

    link_seller(seller_token)
    expect(response).to have_http_status(:ok)
    expect(partner_application.partner_sellers.count).to eq(1)
  end

  it "rejects a token without a seller, from another application, or without the partner scope" do
    client_token = create("doorkeeper/access_token", application: partner_application, resource_owner_id: nil, scopes: "partner_api")
    link_seller(client_token)
    expect(response).to have_http_status(:forbidden)

    other_application = create(:oauth_application, owner: create(:user), confidential: true, scopes: "partner_api")
    link_seller(create("doorkeeper/access_token", application: other_application, resource_owner_id: seller.id, scopes: "partner_api"))
    expect(response).to have_http_status(:forbidden)

    link_seller(create("doorkeeper/access_token", application: partner_application, resource_owner_id: seller.id, scopes: "view_profile"))
    expect(response).to have_http_status(:forbidden)
    expect(PartnerSeller.count).to eq(0)
  end

  it "rejects a partner user ID or a Gumroad account that is already linked to another account" do
    create(:partner_seller, oauth_application: partner_application, user: create(:user), external_user_id: "ext-1")
    link_seller(seller_token)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["message"]).to eq("This Example App account is already linked to a different Gumroad account.")

    create(:partner_seller, oauth_application: partner_application, user: seller, external_user_id: "ext-2")
    link_seller(seller_token, external_user_id: "ext-3")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["message"]).to eq("Your Gumroad account is already linked to a different Example App account.")
  end

  it "rejects a partner user ID that is not valid" do
    link_seller(seller_token, external_user_id: " ")
    expect(response).to have_http_status(:bad_request)

    link_seller(seller_token, external_user_id: "x" * (PartnerMigration::MAX_EXTERNAL_USER_ID_LENGTH + 1))
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["message"]).to start_with("external_user_id must be a string")
  end

  it "does not link a seller whose revocation commits while the request waits for the lock" do
    revoked = false
    allow_any_instance_of(OauthApplication).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      unless revoked
        revoked = true
        partner_application.revoke_access_for(seller)
      end
      original.call(*args, &block)
    end

    link_seller(seller_token)

    expect(response).to have_http_status(:unauthorized)
    expect(PartnerSeller.count).to eq(0)
  end

  it "does not link a suspended account" do
    seller.update!(user_risk_state: "suspended_for_fraud")

    link_seller(seller_token)

    expect(response).to have_http_status(:forbidden)
    expect(PartnerSeller.count).to eq(0)
  end

  it "lets a linked seller confirm a later export as the same partner user" do
    link_seller(seller_token)
    products, = PartnerMigration.normalize_products([{ external_product_id: "texture-pack", name: "Texture Pack", price: 500 }])
    migration, = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)

    migration.claim!(seller, expected_code_digest: migration.code_digest)

    expect(migration.reload.status).to eq(PartnerMigration::STATUS_CLAIMED)
    expect(partner_application.partner_sellers.sole.user).to eq(seller)
  end

  it "unlinks a seller who only linked when the seller revokes the application, but keeps a migrated seller" do
    link_seller(seller_token)
    migrated_seller = create(:user)
    products, = PartnerMigration.normalize_products([{ external_product_id: "texture-pack", name: "Texture Pack", price: 500 }])
    migration, = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-2", products:)
    migration.claim!(migrated_seller, expected_code_digest: migration.code_digest)

    partner_application.revoke_access_for(seller)
    partner_application.revoke_access_for(migrated_seller)

    expect(partner_application.partner_sellers.alive.map(&:user)).to eq([migrated_seller])
  end
end
