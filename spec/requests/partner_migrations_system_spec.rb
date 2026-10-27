# frozen_string_literal: true

require "spec_helper"

describe "Partner migration seller flow", type: :system, js: true, skip_ssrf_stub: true, enforce_product_creation_limit: true do
  include ProductEditPageHelpers

  let(:partner_application) { create(:oauth_application, owner: create(:user), name: "Example App", is_partner: true, confidential: true, scopes: "partner_api") }
  let(:seller) { create(:user, email: "seller@example.com") }
  let(:file_bytes) { File.binread(Rails.root.join("spec/support/fixtures/smilie.png")) }
  let(:file_url) { "https://files.example.com/texture.png" }
  let(:product_attributes) do
    {
      name: "Texture Pack", price: 1500,
      files: [{ url: file_url, display_name: "Texture" }],
      variant_categories: [{ title: "License", variants: [{ name: "Standard" }, { name: "Commercial", price_difference_cents: 3000 }] }],
    }
  end

  before do
    ignore_js_error(/Error retrieving login status, fetch cancelled./)
    WebMock.allow_net_connect!(net_http_connect_on_start: false)
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with("files.example.com").and_return(["93.184.215.14"])
    stub_request(:get, file_url).to_return(status: 200, body: file_bytes, headers: { "Content-Type" => "image/png" })
  end

  def export_catalog(products)
    partner = ActionDispatch::Integration::Session.new(Rails.application)
    partner.host! URI(UrlService.domain_with_protocol).host
    partner.post oauth_token_path, params: {
      grant_type: "client_credentials", client_id: partner_application.uid,
      client_secret: partner_application.secret, scope: "partner_api",
    }
    expect(partner.response).to have_http_status(:ok)
    token = partner.response.parsed_body.fetch("access_token")
    partner.post "/api/v2/partner/migrations", params: { external_user_id: "seller-1", products: }.to_json,
                                               headers: { "CONTENT_TYPE" => "application/json", "AUTHORIZATION" => "Bearer #{token}" }
    expect(partner.response).to have_http_status(:created).or have_http_status(:ok)
    partner.response.parsed_body.fetch("onboarding_url")
  end

  def log_in
    fill_in "Email", with: seller.email
    fill_in "Password", with: seller.password
    click_on "Login"
    expect(page).to have_button("Import products")
  end

  it "keeps the export through a failed login and imports more than the editor's daily quota" do
    catalog = [product_attributes] + Array.new(10) { |index| { name: "Asset #{index + 2}", price: 500 } }
    visit export_catalog(catalog)
    expect(page).to have_content("Connect Example App to Gumroad")
    expect(page).to have_content("Your 11 products will arrive as drafts.")

    fill_in "Email", with: seller.email
    fill_in "Password", with: "wrong-password"
    click_on "Login"
    expect(page).to have_alert("Please try another password. The one you entered was incorrect.")
    expect(page).to have_content("Your 11 products will arrive as drafts.")
    log_in

    expect(page).to have_content(seller.email)
    click_on "Import products"
    expect(page).to have_content("Import started")
    status_path = page.current_path
    migration = PartnerMigration.find_signed!(status_path.split("/").last, purpose: :partner_migration)
    expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
    PartnerMigrationImportJob.new.perform(migration.id)
    visit status_path

    expect(page).to have_content("11 of 11 products imported. 0 failed. 0 remaining.")
    expect(page).to have_link("Review product", count: 11)
    expect(seller.links.count).to eq(11)
    product = seller.links.find_by!(name: "Texture Pack")
    expect(product).to be_draft
    expect(product.alive_product_files.sole.s3_object.get.body.read.b).to eq(file_bytes)
    expect(product.variants.alive.pluck(:name)).to eq(["Standard", "Commercial"])
    expect(migration.reload.results.values).to all(include("product_id"))
    first(:link, "Review product").click
    expect(page).to have_field("Name", with: "Texture Pack")
    select_tab "Content"
    click_on "Publish and continue"
    expect(page).to have_button("Unpublish")
    expect(product.reload).to be_published
    expect(partner_application.partner_sellers.sole.migrated_at).to eq(product.first_published_at)
  end

  it "returns a new account to the export and explains the setup steps" do
    visit export_catalog([product_attributes])
    click_on "Sign up"
    expect(page).to have_content("Sign up for Gumroad and connect Example App")
    expect(page).to have_content("Your 1 product will arrive as drafts.")
    fill_in "Email", with: "new-seller@example.com"
    fill_in "Password", with: SecureRandom.hex(16)
    click_on "Create account"
    expect(page).to have_button("Import products")
    expect(page).to have_content("new-seller@example.com")
    click_on "Import products"
    expect(page).to have_content("Import started")
    status_path = page.current_path
    migration = PartnerMigration.last
    PartnerMigrationImportJob.new.perform(migration.id)
    visit status_path

    expect(page).to have_content("Import complete")
    expect(page).to have_link("confirm your email", href: settings_main_path)
    expect(page).to have_link("set up payouts", href: settings_payments_path)
    expect(page).to have_link("update your profile", href: profile_path)
    expect(migration.reload.user.email).to eq("new-seller@example.com")
    expect(migration.user.links.sole).to be_draft
    expect(partner_application.partner_sellers.sole.migrated_at).to be_nil
  end

  it "retries a failed file after the partner refreshes its URL without duplicating successful products" do
    stub_request(:get, file_url).to_return(status: 403)
    catalog = [product_attributes, { name: "Brush Set", price: 500 }]
    visit export_catalog(catalog)
    log_in
    click_on "Import products"
    expect(page).to have_content("Import started")
    status_path = page.current_path
    migration = PartnerMigration.last
    PartnerMigrationImportJob.new.perform(migration.id)
    visit status_path
    expect(page).to have_content("Import needs attention")
    expect(page).to have_content("1 of 2 products imported. 1 failed.")

    refreshed_url = "#{file_url}?signature=refreshed"
    stub_request(:get, refreshed_url).to_return(status: 200, body: file_bytes)
    export_catalog([product_attributes.merge(files: [{ url: refreshed_url, display_name: "Texture" }]), catalog.last])
    click_on "Retry failed products"
    expect(page).to have_content("Import started")
    PartnerMigrationImportJob.new.perform(migration.id)
    visit status_path

    expect(page).to have_content("2 of 2 products imported. 0 failed. 0 remaining.")
    expect(seller.links.pluck(:name)).to contain_exactly("Texture Pack", "Brush Set")
    expect(PartnerMigration.count).to eq(1)
  end
end
