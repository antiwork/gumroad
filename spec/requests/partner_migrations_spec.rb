# frozen_string_literal: true

require "spec_helper"

describe "Partner migration onboarding", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:partner_application) { create(:oauth_application, owner: create(:user), name: "Example App", is_partner: true, confidential: true, scopes: "partner_api") }
  let(:seller) { create(:named_user) }
  let!(:migration_and_code) do
    products, _error = PartnerMigration.normalize_products([{ name: "Texture Pack", price: 1500 }, { name: "Brush Set", price: 500 }])
    PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)
  end
  let(:migration) { migration_and_code.first }
  let(:code) { migration_and_code.last }

  before do
    host! DOMAIN
    stub_vite_layout_helpers
  end

  it "removes the code from the URL and asks a logged-out visitor to log in" do
    get partner_migration_path(migration_code: code)

    expect(response).to redirect_to(partner_migration_path)

    get partner_migration_path

    expect(response).to redirect_to(login_path(next: partner_migration_path))
    expect(response.location).not_to include(code)
  end

  it "redacts the code from the request log" do
    logged_paths = []
    subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") { |event| logged_paths << event.payload[:path] }

    get partner_migration_path(migration_code: code)

    ActiveSupport::Notifications.unsubscribe(subscriber)
    expect(logged_paths).to eq(["/partner_migration?migration_code=[FILTERED]"])
  end

  it "asks the logged-in seller to confirm the import" do
    sign_in seller

    get partner_migration_path(migration_code: code)
    follow_redirect!

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Import 2 products from")
    expect(response.body).to include("Example App")
  end

  it "claims the migration and starts the import" do
    sign_in seller
    get partner_migration_path(migration_code: code)

    claim

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Import started")
    expect(migration.reload).to have_attributes(status: PartnerMigration::STATUS_CLAIMED, user: seller)
    expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
  end

  it "does not accept a used link from another account" do
    sign_in seller
    get partner_migration_path(migration_code: code)
    claim
    sign_out seller

    sign_in create(:named_user)
    get partner_migration_path(migration_code: code)
    follow_redirect!

    expect(response.body).to include("This link is invalid or expired.")
    expect(migration.reload.user).to eq(seller)
  end

  it "rejects a form for a different link than the one in the session" do
    products, _error = PartnerMigration.normalize_products([{ name: "Brush Set", price: 500 }])
    other_migration, other_code = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-2", products:)
    sign_in seller
    get partner_migration_path(migration_code: code)
    get partner_migration_path
    form = Nokogiri::HTML(response.body)

    get partner_migration_path(migration_code: other_code)
    post partner_migration_path, params: {
      authenticity_token: form.at_css("input[name='authenticity_token']")["value"],
      partner_migration_id: form.at_css("input[name='partner_migration_id']")["value"],
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("This page is out of date.")
    expect(migration.reload).to be_pending
    expect(other_migration.reload).to be_pending
  end

  it "shows an error for an unknown code" do
    sign_in seller

    get partner_migration_path(migration_code: "unknown")
    claim

    expect(response).to have_http_status(:unprocessable_entity)
    expect(migration.reload).to be_pending
  end

  def claim
    get partner_migration_path
    doc = Nokogiri::HTML(response.body)
    authenticity_token = doc.at_css("input[name='authenticity_token']")&.[]("value") || doc.at_css("meta[name='csrf-token']")["content"]
    post partner_migration_path, params: { authenticity_token:, partner_migration_id: doc.at_css("input[name='partner_migration_id']")&.[]("value") }
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
