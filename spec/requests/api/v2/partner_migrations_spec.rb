# frozen_string_literal: true

require "spec_helper"

describe "Partner API migrations", type: :request do
  let(:partner_application) { create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api") }
  let(:token) { create("doorkeeper/access_token", application: partner_application, resource_owner_id: nil, scopes: "partner_api") }
  let(:products) { [{ name: "Texture Pack", price: 1500, files: [{ url: "https://files.example.com/pack.zip", display_name: "Pack" }] }] }

  before do
    host! "test.gumroad.com"
  end

  def post_migration(body)
    post "/api/v2/partner/migrations", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json", "AUTHORIZATION" => "Bearer #{token.token}" }
  end

  it "stores the products and returns a one-time onboarding link" do
    expect do
      post_migration(external_user_id: "ext-1", products:)
    end.to change { PartnerMigration.count }.by(1)

    expect(response).to have_http_status(:created)
    migration = PartnerMigration.last
    onboarding_url = response.parsed_body["onboarding_url"]
    code = Rack::Utils.parse_query(URI(onboarding_url).query)["migration_code"]
    expect(onboarding_url).to eq(partner_migration_url(migration_code: code, host: DOMAIN, protocol: PROTOCOL))
    expect(PartnerMigration.find_by_code(code)).to eq(migration)
    expect(response.parsed_body["expires_at"]).to eq(migration.expires_at.iso8601)
    expect(migration).to have_attributes(oauth_application: partner_application, external_user_id: "ext-1", status: PartnerMigration::STATUS_PENDING)
    expect(migration.products.first).to include("name" => "Texture Pack", "files" => [{ "url" => "https://files.example.com/pack.zip", "display_name" => "Pack" }])
  end

  it "rejects a missing external user ID" do
    post_migration(products:)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["message"]).to eq("external_user_id must be a string with 1 to 255 characters, not only spaces.")
  end

  it "rejects an external user ID with only spaces" do
    expect do
      post_migration(external_user_id: "   ", products:)
    end.not_to change { PartnerMigration.count }

    expect(response).to have_http_status(:bad_request)
  end

  it "keeps the partner user ID exactly as sent" do
    ["ext-1", "EXT-1", "ext-1 "].each { post_migration(external_user_id: _1, products:) }

    expect(PartnerMigration.where(oauth_application: partner_application).pluck(:external_user_id)).to contain_exactly("ext-1", "EXT-1", "ext-1 ")
    expect(PartnerMigration.where(external_user_id: "ext-1").count).to eq(1)
  end

  it "rejects products that are not valid" do
    expect do
      post_migration(external_user_id: "ext-1", products: [{ name: "No price" }])
    end.not_to change { PartnerMigration.count }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["message"]).to eq("products[0]: price must be a whole number of cents, 0 or more.")
  end

  it "rejects an application that is not a partner" do
    partner_application.update!(is_partner: false)

    post_migration(external_user_id: "ext-1", products:)

    expect(response).to have_http_status(:forbidden)
  end

  it "returns the same migration when the partner sends an export again" do
    post_migration(external_user_id: "ext-1", products:)
    first_id = response.parsed_body.fetch("migration_id")

    expect { post_migration(external_user_id: "ext-1", products:) }.not_to change { PartnerMigration.count }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("migration_id")).to eq(first_id)
  end

  it "keeps the accepted catalog when a changed export conflicts with it" do
    post_migration(external_user_id: "ext-1", products:)
    migration = PartnerMigration.last
    migration.claim!(create(:user), expected_code_digest: migration.code_digest)

    post_migration(external_user_id: "ext-1", products: [{ name: "Another product", price: 1500 }])

    expect(response).to have_http_status(:conflict)
    expect(migration.reload.products.first["name"]).to eq("Texture Pack")
  end

  it "rejects an option name that does not fit the product model" do
    categories = [{ title: "License", variants: [{ name: "x" * (PartnerMigration::MAX_NAME_LENGTH + 1) }] }]

    post_migration(external_user_id: "ext-1", products: [{ name: "Asset", price: 1500, variant_categories: categories }])

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["message"]).to include("products[0]", "variant name")
  end

  it "returns import progress only to the partner that created it" do
    post_migration(external_user_id: "ext-1", products:)
    migration_id = response.parsed_body.fetch("migration_id")

    get "/api/v2/partner/migrations/#{migration_id}", params: { access_token: token.token }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "pending", "total" => 1, "imported" => 0, "remaining" => 1)
    another_application = create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api")
    another_token = create("doorkeeper/access_token", application: another_application, resource_owner_id: nil, scopes: "partner_api")

    get "/api/v2/partner/migrations/#{migration_id}", params: { access_token: another_token.token }

    expect(response).to have_http_status(:not_found)
  end
end
