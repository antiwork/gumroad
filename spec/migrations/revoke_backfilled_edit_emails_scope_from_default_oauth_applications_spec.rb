# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261201000002_revoke_backfilled_edit_emails_scope_from_default_oauth_applications").to_s

describe RevokeBackfilledEditEmailsScopeFromDefaultOauthApplications do
  subject(:migration) { described_class.new }

  let(:seller) { create(:user) }
  let(:old_scopes) { described_class::OLD_PUBLIC_SCOPES }
  let(:old_scopes_string) { old_scopes.join(" ") }
  let(:backfilled_scopes_string) do
    old_scopes.dup.insert(old_scopes.index("edit_products") + 1, described_class::NEW_SCOPE).join(" ")
  end
  let(:custom_scopes_string) { "edit_products edit_emails" }
  let(:before_scope_deploy) { described_class::EDIT_EMAILS_SCOPE_DEPLOYED_AT - 1.second }
  let(:after_scope_deploy) { described_class::EDIT_EMAILS_SCOPE_DEPLOYED_AT + 1.second }

  def create_access_token(application:, resource_owner:, scopes:)
    create(
      "doorkeeper/access_token",
      application:,
      resource_owner_id: resource_owner.id,
      scopes:
    )
  end

  def create_access_grant(application:, resource_owner:, scopes:)
    Doorkeeper::AccessGrant.create!(
      application_id: application.id,
      resource_owner_id: resource_owner.id,
      redirect_uri: application.redirect_uri,
      expires_in: 1.day.to_i,
      scopes:
    )
  end

  it "revokes the backfilled scope from affected applications and matching credentials" do
    affected_application = create(:oauth_application, owner: seller, scopes: backfilled_scopes_string, created_at: before_scope_deploy)
    affected_token = create_access_token(application: affected_application, resource_owner: seller, scopes: "edit_emails")
    affected_grant = create_access_grant(application: affected_application, resource_owner: seller, scopes: "edit_products edit_emails")
    affected_device_authorization = create(:oauth_device_authorization, oauth_application: affected_application, scopes: "view_profile edit_emails")
    affected_device_authorization_with_only_edit_emails = create(:oauth_device_authorization, oauth_application: affected_application, scopes: "edit_emails")
    custom_application = create(:oauth_application, owner: seller, scopes: custom_scopes_string)
    custom_token = create_access_token(application: custom_application, resource_owner: seller, scopes: custom_scopes_string)
    custom_grant = create_access_grant(application: custom_application, resource_owner: seller, scopes: custom_scopes_string)
    custom_device_authorization = create(:oauth_device_authorization, oauth_application: custom_application, scopes: custom_scopes_string)

    migration.up

    expect(affected_application.reload.scopes.to_s).to eq(old_scopes_string)
    expect(affected_token.reload.scopes.to_s).to eq("")
    expect(affected_grant.reload.scopes.to_s).to eq("edit_products")
    expect(affected_device_authorization.reload.scopes).to eq("view_profile")
    expect { affected_device_authorization_with_only_edit_emails.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(custom_application.reload.scopes.to_s).to eq(custom_scopes_string)
    expect(custom_token.reload.scopes.to_s).to eq(custom_scopes_string)
    expect(custom_grant.reload.scopes.to_s).to eq(custom_scopes_string)
    expect(custom_device_authorization.reload.scopes).to eq(custom_scopes_string)
  end

  it "revokes matching credentials when a previous attempt already updated the application" do
    application = create(:oauth_application, owner: seller, scopes: old_scopes_string, created_at: before_scope_deploy)
    access_token = create_access_token(application:, resource_owner: seller, scopes: "edit_emails")
    access_grant = create_access_grant(application:, resource_owner: seller, scopes: "edit_products edit_emails")
    device_authorization = create(:oauth_device_authorization, oauth_application: application, scopes: "view_profile edit_emails")

    migration.up

    expect(application.reload.scopes.to_s).to eq(old_scopes_string)
    expect(access_token.reload.scopes.to_s).to eq("")
    expect(access_grant.reload.scopes.to_s).to eq("edit_products")
    expect(device_authorization.reload.scopes).to eq("view_profile")
  end

  it "normalizes legacy blank-scope applications and revokes matching credentials" do
    application = create(:oauth_application, owner: seller, scopes: old_scopes_string, created_at: before_scope_deploy)
    application.update_columns(scopes: "")
    access_token = create_access_token(application:, resource_owner: seller, scopes: "edit_emails")
    access_grant = create_access_grant(application:, resource_owner: seller, scopes: "edit_products edit_emails")
    device_authorization = create(:oauth_device_authorization, oauth_application: application, scopes: "edit_emails")

    migration.up

    expect(application.reload.scopes.to_s).to eq(old_scopes_string)
    expect(access_token.reload.scopes.to_s).to eq("")
    expect(access_grant.reload.scopes.to_s).to eq("edit_products")
    expect { device_authorization.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "preserves default scopes for applications created after edit_emails was deployed" do
    application = create(:oauth_application, owner: seller, scopes: backfilled_scopes_string, created_at: after_scope_deploy)
    access_token = create_access_token(application:, resource_owner: seller, scopes: backfilled_scopes_string)
    access_grant = create_access_grant(application:, resource_owner: seller, scopes: backfilled_scopes_string)
    device_authorization = create(:oauth_device_authorization, oauth_application: application, scopes: backfilled_scopes_string)

    migration.up

    expect(application.reload.scopes.to_s).to eq(backfilled_scopes_string)
    expect(access_token.reload.scopes.to_s).to eq(backfilled_scopes_string)
    expect(access_grant.reload.scopes.to_s).to eq(backfilled_scopes_string)
    expect(device_authorization.reload.scopes).to eq(backfilled_scopes_string)
  end

  it "revokes over-scoped credentials for applications that do not allow edit_emails" do
    application = create(:oauth_application, owner: seller, scopes: "edit_products", created_at: after_scope_deploy)
    access_token = create_access_token(application:, resource_owner: seller, scopes: "edit_products edit_emails")
    access_grant = create_access_grant(application:, resource_owner: seller, scopes: "edit_products edit_emails")
    device_authorization = create(:oauth_device_authorization, oauth_application: application, scopes: "view_profile edit_emails")
    device_authorization_with_only_edit_emails = create(:oauth_device_authorization, oauth_application: application, scopes: "edit_emails")

    migration.up

    expect(application.reload.scopes.to_s).to eq("edit_products")
    expect(access_token.reload.scopes.to_s).to eq("edit_products")
    expect(access_grant.reload.scopes.to_s).to eq("edit_products")
    expect(device_authorization.reload.scopes).to eq("view_profile")
    expect { device_authorization_with_only_edit_emails.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "does not grant edit_emails when the corrective migration is rolled back" do
    default_application = create(:oauth_application, owner: seller, scopes: old_scopes_string)

    migration.down

    expect(default_application.reload.scopes.to_s).to eq(old_scopes_string)
  end
end
