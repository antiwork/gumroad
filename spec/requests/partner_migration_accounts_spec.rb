# frozen_string_literal: true

require "spec_helper"

describe "Partner migration onboarding for a seller without a Gumroad account", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:partner_application) { create(:oauth_application, owner: create(:user), name: "Example App", is_partner: true, confidential: true, scopes: "partner_api") }
  let(:emailed_tokens) { [] }
  let!(:migration_and_code) do
    products, _error = PartnerMigration.normalize_products([{ name: "Texture Pack", price: 1500 }, { name: "Brush Set", price: 500 }])
    PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:, email: "new-seller@example.com", profile: { "name" => "Ada" })
  end
  let(:migration) { migration_and_code.first }
  let(:code) { migration_and_code.last }

  before do
    host! DOMAIN
    stub_vite_layout_helpers
    allow(CreatorMailer).to receive(:partner_migration_account_setup).and_wrap_original do |original, id, encrypted_token|
      emailed_tokens << PartnerMigration.decrypt_account_setup_token(encrypted_token)
      original.call(id, encrypted_token)
    end
  end

  def open_onboarding_link
    get partner_migration_path(migration_code: code)
    follow_redirect!
  end

  def create_account
    open_onboarding_link
    post_create_account
    follow_redirect!
  end

  def post_create_account
    form = Nokogiri::HTML(response.body).at_css("form[action='#{create_partner_migration_account_path}']")
    post create_partner_migration_account_path, params: form.css("input[type='hidden']").to_h { [_1["name"], _1["value"]] }
  end

  def setup_form_fields
    Nokogiri::HTML(response.body).css("form[action='#{partner_migration_account_setup_path}'] input[type='hidden']").to_h { [_1["name"], _1["value"]] }
  end

  def form_token(path)
    Nokogiri::HTML(response.body).at_css("form[action='#{path}'] input[name='authenticity_token']")["value"]
  end

  it "creates the account only when the seller asks, so fetching the link does nothing" do
    expect { open_onboarding_link }.not_to change { User.count }

    expect(response.body).to include("Move 2 products from Example App to Gumroad?", "n•••@example.com", "Create my account", "I already have a Gumroad account")
    expect(migration.reload).to be_pending
  end

  it "creates the account, starts the import, and asks the seller to check their email" do
    expect { create_account }.to have_enqueued_mail(CreatorMailer, :partner_migration_account_setup)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Check your email", "n•••@example.com", "Resend email")
    user = User.find_by!(email: "new-seller@example.com")
    expect(user.name).to eq("Ada")
    expect(SignupEvent.where(user_id: user.id).count).to eq(1)
    expect(migration.reload).to have_attributes(status: PartnerMigration::STATUS_CLAIMED, user:)
    expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)

    expect { open_onboarding_link }.not_to change { User.count }
    expect(response.body).to include("Check your email")
  end

  it "asks a seller whose email has an account to log in and confirm" do
    create(:user, email: "new-seller@example.com")

    get partner_migration_path(migration_code: code)
    follow_redirect!

    expect(response).to redirect_to(login_path(next: partner_migration_path))
    expect(migration.reload).to be_pending
  end

  it "lets the seller set a password from the emailed link and opens the products page" do
    create_account
    token = emailed_tokens.sole

    get partner_migration_account_setup_path(account_setup_token: token)
    expect(response).to redirect_to(partner_migration_account_setup_path)
    follow_redirect!
    expect(response.body).to include("Set your password", "new-seller@example.com")

    post partner_migration_account_setup_path, params: { password: "a-long-new-password-123", **setup_form_fields }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Accept the Terms of Use to continue.")

    post partner_migration_account_setup_path, params: { password: "a-long-new-password-123", terms_accepted: "1", **setup_form_fields }
    expect(response).to redirect_to(products_path)
    expect(flash[:notice]).to eq("We're importing your 2 products from Example App. They appear here as drafts.")
    seller = migration.reload.user
    expect(seller).to be_confirmed

    sign_out seller
    get partner_migration_account_setup_path(account_setup_token: token)
    follow_redirect!
    expect(response.body).to include("This link expired", "Use the link in the newest email we sent you.")
    expect(Nokogiri::HTML(response.body).at_css("a[href='#{new_user_password_path}']").text).to eq("Reset my password")
  end

  it "checks the generated password for breaches before it locks the partner application" do
    open_onboarding_link
    outer_transactions = ActiveRecord::Base.connection.open_transactions
    checked_under_lock = []
    allow_any_instance_of(Pwned::Password).to receive(:pwned_count) do
      checked_under_lock << (ActiveRecord::Base.connection.open_transactions > outer_transactions)
      0
    end

    post_create_account

    expect(checked_under_lock).to eq([false])
    expect(User.find_by(email: "new-seller@example.com")).to be_present
  end

  it "checks the new password for breaches before it locks the migration" do
    create_account
    get partner_migration_account_setup_path(account_setup_token: emailed_tokens.sole)
    follow_redirect!
    outer_transactions = ActiveRecord::Base.connection.open_transactions
    checked_under_lock = []
    allow_any_instance_of(Pwned::Password).to receive(:pwned_count) do
      checked_under_lock << (ActiveRecord::Base.connection.open_transactions > outer_transactions)
      0
    end

    post partner_migration_account_setup_path, params: { password: "a-long-new-password-123", terms_accepted: "1", **setup_form_fields }

    expect(response).to redirect_to(products_path)
    expect(checked_under_lock).to eq([false])
  end

  it "tells a seller who sets the password after the import finished that the drafts are ready" do
    create_account
    PartnerMigrationImportJob.new.perform(migration.id)
    get partner_migration_account_setup_path(account_setup_token: emailed_tokens.sole)
    follow_redirect!

    post partner_migration_account_setup_path, params: { password: "a-long-new-password-123", terms_accepted: "1", **setup_form_fields }

    expect(response).to redirect_to(products_path)
    expect(flash[:notice]).to eq("Your 2 products from Example App are here as drafts.")
  end

  it "signs in with the new password's session salt, so the session survives the next request" do
    create_account
    get partner_migration_account_setup_path(account_setup_token: emailed_tokens.sole)
    follow_redirect!
    post partner_migration_account_setup_path, params: { password: "a-long-new-password-123", terms_accepted: "1", **setup_form_fields }

    _user_key, session_salt = session["warden.user.user.key"]
    expect(session_salt).to eq(migration.reload.user.authenticatable_salt)
    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it "remembers this browser, so the seller's next login skips two-factor authentication, as after signup" do
    create_account
    get partner_migration_account_setup_path(account_setup_token: emailed_tokens.sole)
    follow_redirect!
    post partner_migration_account_setup_path, params: { password: "a-long-new-password-123", terms_accepted: "1", **setup_form_fields }
    seller = migration.reload.user
    expect(seller.two_factor_authentication_enabled?).to be(true)
    sign_out seller

    get login_path
    post login_path, params: { user: { login_identifier: seller.email, password: "a-long-new-password-123" }, authenticity_token: Nokogiri::HTML(response.body).at_css("meta[name='csrf-token']")["content"] }

    expect(controller.current_user).to eq(seller)
    expect(response.location).not_to include(two_factor_authentication_path)
  end

  it "rejects a create-account form for a different link than the one in the session" do
    products, _error = PartnerMigration.normalize_products([{ name: "Brush Set", price: 500 }])
    _other_migration, other_code = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-2", products:, email: "other@example.com")
    open_onboarding_link
    form = Nokogiri::HTML(response.body).at_css("form[action='#{create_partner_migration_account_path}']")
    form_params = form.css("input[type='hidden']").to_h { [_1["name"], _1["value"]] }

    get partner_migration_path(migration_code: other_code)
    post create_partner_migration_account_path, params: form_params

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("This page is out of date.")
    expect(User.where(email: ["new-seller@example.com", "other@example.com"])).to be_empty
  end

  it "rejects a set-password form for a different setup link than the one in the session" do
    create_account
    get partner_migration_account_setup_path(account_setup_token: emailed_tokens.sole)
    follow_redirect!
    first_page_fields = setup_form_fields
    products, = PartnerMigration.normalize_products([{ name: "Brush Set", price: 500 }])
    other_migration, = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-2", products:, email: "other@example.com")
    other_migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: other_migration.code_digest)
    get partner_migration_account_setup_path(account_setup_token: emailed_tokens.last)
    follow_redirect!
    expect(response.body).to include("other@example.com")

    post partner_migration_account_setup_path, params: { password: "a-long-new-password-123", terms_accepted: "1", **first_page_fields }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("This page is out of date.")
    expect(User.find_by!(email: "other@example.com").valid_password?("a-long-new-password-123")).to be(false)
  end

  it "keeps a valid setup token when a link with an unknown token opens" do
    create_account
    get partner_migration_account_setup_path(account_setup_token: emailed_tokens.sole)

    get partner_migration_account_setup_path(account_setup_token: "unknown-token")
    follow_redirect!

    expect(response.body).to include("Set your password", "new-seller@example.com")
  end

  it "tells the seller why the account cannot be created" do
    PartnerSeller.create!(oauth_application: partner_application, user: create(:user), external_user_id: "ext-1")
    open_onboarding_link

    post_create_account

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("This Example App account is already linked to a different Gumroad account.")
  end

  it "points a seller whose setup link expired to the password reset" do
    create_account

    travel_to((PartnerMigration::ACCOUNT_SETUP_EXPIRES_IN + 1.minute).from_now) do
      open_onboarding_link
    end

    expect(response.body).to include("Your setup link expired", "n•••@example.com")
    expect(Nokogiri::HTML(response.body).at_css("a[href='#{new_user_password_path}']").text).to eq("Reset my password")
  end

  it "sends the email again on request, at most once a minute" do
    create_account

    post resend_partner_migration_account_setup_path, params: { authenticity_token: form_token(resend_partner_migration_account_setup_path) }
    follow_redirect!
    expect(response.body).to include("Wait a minute, then ask for another email.")
    expect(response.headers["Refresh"]).to be_nil

    travel_to((PartnerMigration::ACCOUNT_SETUP_RESEND_INTERVAL + 1.second).from_now) do
      post resend_partner_migration_account_setup_path, params: { authenticity_token: form_token(resend_partner_migration_account_setup_path) }
      follow_redirect!
    end
    expect(response.body).to include("We sent the email again.")
    expect(emailed_tokens.size).to eq(2)
  end

  it "keeps the setup token out of the email headers that record the mailer arguments" do
    create_account
    encrypted_token = PartnerMigration.encrypt_account_setup_token("secret-setup-token")

    [MailerInfo::EMAIL_PROVIDER_SENDGRID, MailerInfo::EMAIL_PROVIDER_RESEND].each do |email_provider|
      allow(MailerInfo).to receive(:random_delivery_method_options).and_return(MailerInfo::DeliveryMethod.options(domain: :gumroad, email_provider:))
      mail = CreatorMailer.partner_migration_account_setup(migration.id, encrypted_token).deliver_now
      resend_args = mail.header[MailerInfo.header_name(:mailer_args)]&.value

      headers = mail.header.fields.map { _1.value.to_s }.push(resend_args && MailerInfo.decrypt(resend_args)).join
      expect(headers).not_to include(encrypted_token), "#{email_provider} headers hold the token"
    end
  end

  it "redacts the setup token from the request log" do
    logged_paths = []
    subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") { |event| logged_paths << event.payload[:path] }

    get partner_migration_account_setup_path(account_setup_token: "secret-token")

    ActiveSupport::Notifications.unsubscribe(subscriber)
    expect(logged_paths).to eq(["/partner_migration/setup?account_setup_token=[FILTERED]"])
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
