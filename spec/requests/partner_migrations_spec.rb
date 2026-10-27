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
    expect(Nokogiri::HTML(response.body).at_css("input[name='partner_migration_id']")["value"]).to eq(migration.public_id)
  end

  it "keeps the export while an account without an email adds an address" do
    seller.update_columns(provider: "apple", email: nil, unconfirmed_email: nil)
    sign_in seller
    get partner_migration_path(migration_code: code)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("add an email address", "Use another account")
    expect(migration.reload).to be_pending

    seller.update!(email: "seller@example.com")
    get partner_migration_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Import 2 products from", "seller@example.com")
  end

  it "lets an account without an email switch accounts before importing" do
    seller.update_columns(provider: "apple", email: nil, unconfirmed_email: nil)
    sign_in seller
    get partner_migration_path(migration_code: code)
    follow_redirect!
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("form[action='#{partner_migration_path}'] button[disabled]")).to be_present
    form = doc.at_css("form[action='#{switch_partner_migration_account_path}']")

    post switch_partner_migration_account_path, params: { authenticity_token: form.at_css("input[name='authenticity_token']")["value"] }

    expect(response).to redirect_to(login_path(next: partner_migration_path))
    sign_in create(:named_user)
    get partner_migration_path
    expect(response.body).to include("Import 2 products from", "Example App")
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
    form = Nokogiri::HTML(response.body).at_css("form[action='#{partner_migration_path}']")

    get partner_migration_path(migration_code: other_code)
    post partner_migration_path, params: {
      authenticity_token: form.at_css("input[name='authenticity_token']")["value"],
      partner_migration_id: form.at_css("input[name='partner_migration_id']")["value"],
      partner_migration_code_digest: form.at_css("input[name='partner_migration_code_digest']")["value"],
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

  it "requires a new confirmation when another tab opens an updated export for the same seller" do
    sign_in seller
    get partner_migration_path(migration_code: code)
    get partner_migration_path
    form = Nokogiri::HTML(response.body).at_css("form[action='#{partner_migration_path}']")
    old_params = form.css("input").to_h { [_1["name"], _1["value"]] }
    products, = PartnerMigration.normalize_products([{ name: "Updated catalog", price: 500 }])
    _migration, refreshed_code = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: migration.external_user_id, products:)
    get partner_migration_path(migration_code: refreshed_code)

    post partner_migration_path, params: old_params

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("This page is out of date.")
    expect(migration.reload).to be_pending
  end

  it "rejects a catalog refreshed after the form check and before the claim locks" do
    sign_in seller
    get partner_migration_path(migration_code: code)
    allow_any_instance_of(PartnerMigration).to receive(:claim!).and_wrap_original do |original, claimer, **kwargs|
      products, = PartnerMigration.normalize_products([{ name: "Updated catalog", price: 500 }])
      PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: migration.external_user_id, products:)
      original.call(claimer, **kwargs)
    end

    claim

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("This page is out of date.")
    expect(migration.reload).to be_pending
    expect(partner_application.partner_sellers).to be_empty
    expect(PartnerMigrationImportJob.jobs).to be_empty
  end

  it "lets two partner users whose IDs differ only in case each claim their own link" do
    products, _error = PartnerMigration.normalize_products([{ name: "Brush Set", price: 500 }])
    other_migration, other_code = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "EXT-1", products:)
    other_seller = create(:named_user)

    sign_in seller
    get partner_migration_path(migration_code: code)
    claim
    expect(response.body).to include("Import started")
    sign_out seller

    sign_in other_seller
    get partner_migration_path(migration_code: other_code)
    claim

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Import started")
    expect(migration.reload.user).to eq(seller)
    expect(other_migration.reload.user).to eq(other_seller)
    expect(partner_application.partner_sellers.pluck(:external_user_id, :user_id)).to contain_exactly(["ext-1", seller.id], ["EXT-1", other_seller.id])
  end

  it "keeps the migration when the seller switches accounts" do
    sign_in seller
    get partner_migration_path(migration_code: code)
    follow_redirect!
    form = Nokogiri::HTML(response.body).at_css("form[action='#{switch_partner_migration_account_path}']")

    post switch_partner_migration_account_path, params: { authenticity_token: form.at_css("input[name='authenticity_token']")["value"] }

    expect(response).to redirect_to(login_path(next: partner_migration_path))
    sign_in create(:named_user)
    get partner_migration_path
    expect(response.body).to include("Import 2 products from", "Example App")
  end

  it "keeps the return path after a failed login" do
    get partner_migration_path(migration_code: code)
    follow_redirect!
    follow_redirect!
    doc = Nokogiri::HTML(response.body)

    post login_path, params: { user: { login_identifier: seller.email, password: "wrong" }, next: partner_migration_path, authenticity_token: doc.at_css("meta[name='csrf-token']")["content"] }

    expect(response).to redirect_to(login_path(next: partner_migration_path))
  end

  it "shows results on a persistent page without the onboarding code" do
    sign_in seller
    get partner_migration_path(migration_code: code)
    claim
    status_address = request.path
    expect(status_address).to eq(partner_migration_status_path(migration.public_id))
    PartnerMigrationImportJob.new.perform(migration.id)

    get status_address

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Import complete", "2 of 2 products imported", "Review product")
    expect(status_address).not_to include(code)
    sign_out seller
    sign_in create(:named_user)
    get status_address
    expect(response).to have_http_status(:not_found)
  end

  it "shows product errors and media warnings without losing successful products" do
    migration.claim!(seller, expected_code_digest: migration.code_digest)
    product = create(:product, user: seller, name: "Texture Pack")
    migration.update!(status: PartnerMigration::STATUS_FAILED, results: {
                        "0" => { "product_id" => product.external_id, "warnings" => ["Cover could not be imported."] },
                        "1" => { "error" => "The file link expired." },
                      })
    sign_in seller

    get partner_migration_status_path(migration.public_id)

    expect(response.body).to include("Import needs attention", "1 of 2 products imported", "Cover could not be imported.", "The file link expired.", "Retry failed products")
    form = Nokogiri::HTML(response.body).at_css("form[action='#{retry_partner_migration_path(migration.public_id)}']")
    post retry_partner_migration_path(migration.public_id), params: { authenticity_token: form.at_css("input[name='authenticity_token']")["value"] }
    expect(response).to have_http_status(:see_other)
    expect(migration.reload.results).to eq("0" => { "product_id" => product.external_id, "warnings" => ["Cover could not be imported."] })
  end

  it "opens the status page from a link issued before Nano IDs, only for its owner" do
    migration.claim!(seller, expected_code_digest: migration.code_digest)
    legacy_path = partner_migration_status_path(migration.signed_id(purpose: :partner_migration))
    sign_in seller

    get legacy_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Import started")
    sign_out seller
    sign_in create(:named_user)
    get legacy_path
    expect(response).to have_http_status(:not_found)
  end

  it "does not open the status page for a row ID, another case, or extra characters" do
    migration.claim!(seller, expected_code_digest: migration.code_digest)
    sign_in seller

    [migration.id.to_s, migration.public_id.swapcase, "#{migration.public_id} ", "#{migration.public_id}x"].each do |value|
      next if value == migration.public_id

      get partner_migration_status_path(value)

      expect(response).to have_http_status(:not_found), "returned #{response.status} for #{value.inspect}"
    end
  end

  it "does not open the status page while the owner is impersonating another user" do
    admin = create(:admin_user)
    migration.claim!(admin, expected_code_digest: migration.code_digest)
    sign_in admin
    $redis.set(RedisKey.impersonated_user(admin.id), seller.id)

    get partner_migration_status_path(migration.public_id)

    expect(response).to have_http_status(:not_found)
  ensure
    $redis.del(RedisKey.impersonated_user(admin.id)) if defined?(admin) && admin&.persisted?
  end

  def claim
    get partner_migration_path
    doc = Nokogiri::HTML(response.body)
    form = doc.at_css("form[action='#{partner_migration_path}']")
    authenticity_token = form&.at_css("input[name='authenticity_token']")&.[]("value") || doc.at_css("meta[name='csrf-token']")["content"]
    post partner_migration_path, params: {
      authenticity_token:,
      partner_migration_id: form&.at_css("input[name='partner_migration_id']")&.[]("value"),
      partner_migration_code_digest: form&.at_css("input[name='partner_migration_code_digest']")&.[]("value"),
    }
    follow_redirect! if response.redirect?
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
