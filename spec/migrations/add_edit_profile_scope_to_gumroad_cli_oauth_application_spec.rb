# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261206000001_add_edit_profile_scope_to_gumroad_cli_oauth_application").to_s

describe AddEditProfileScopeToGumroadCliOauthApplication do
  subject(:migration) { described_class.new }

  let(:seller) { create(:user) }

  def create_cli_application(scopes:)
    create(
      :oauth_application,
      owner: seller,
      uid: described_class::CLI_CLIENT_ID,
      scopes:
    )
  end

  def create_access_token(application:, scopes:)
    create(
      "doorkeeper/access_token",
      application:,
      resource_owner_id: seller.id,
      scopes:
    )
  end

  def create_access_grant(application:, scopes:)
    Doorkeeper::AccessGrant.create!(
      application_id: application.id,
      resource_owner_id: seller.id,
      redirect_uri: application.redirect_uri,
      expires_in: 1.day.to_i,
      scopes:
    )
  end

  it "appends edit_profile to the CLI application's scopes" do
    application = create_cli_application(scopes: "edit_products view_sales mark_sales_as_shipped edit_sales view_payouts view_profile account")

    migration.up

    expect(application.reload.scopes.to_s).to eq("edit_products view_sales mark_sales_as_shipped edit_sales view_payouts view_profile account edit_profile")
  end

  it "does not duplicate the scope when it is already present" do
    application = create_cli_application(scopes: "view_profile edit_profile account")

    migration.up

    expect(application.reload.scopes.to_s).to eq("view_profile edit_profile account")
  end

  it "leaves other applications untouched" do
    other_application = create(:oauth_application, owner: seller, scopes: "account")

    create_cli_application(scopes: "account")
    migration.up

    expect(other_application.reload.scopes.to_s).to eq("account")
  end

  it "removes the scope on rollback" do
    application = create_cli_application(scopes: "view_profile edit_profile account")

    migration.down

    expect(application.reload.scopes.to_s).to eq("view_profile account")
  end

  it "removes the scope on rollback even when up was a no-op because the scope pre-existed" do
    application = create_cli_application(scopes: "view_profile edit_profile account")

    migration.up
    migration.down

    expect(application.reload.scopes.to_s).to eq("view_profile account")
  end

  it "revokes the scope from issued credentials on rollback" do
    application = create_cli_application(scopes: "view_profile edit_profile account")
    token = create_access_token(application:, scopes: "account edit_profile")
    grant = create_access_grant(application:, scopes: "edit_profile account")
    device_authorization = create(:oauth_device_authorization, oauth_application: application, scopes: "view_profile edit_profile")
    device_authorization_with_only_edit_profile = create(:oauth_device_authorization, oauth_application: application, scopes: "edit_profile")

    migration.down

    expect(token.reload.scopes.to_s).to eq("account")
    expect(grant.reload.scopes.to_s).to eq("account")
    expect(device_authorization.reload.scopes).to eq("view_profile")
    expect { device_authorization_with_only_edit_profile.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "leaves credentials of other applications untouched on rollback" do
    other_application = create(:oauth_application, owner: seller, scopes: "account edit_profile")
    other_token = create_access_token(application: other_application, scopes: "account edit_profile")

    create_cli_application(scopes: "view_profile edit_profile account")
    migration.down

    expect(other_token.reload.scopes.to_s).to eq("account edit_profile")
  end

  # Regression: a device poll can mint a token from an approved authorization's
  # stored scopes while the rollback is running. The old cleanup order swept
  # access tokens FIRST, so a token minted after that sweep (but before the
  # device authorization was cleaned) kept edit_profile forever. Tokens are now
  # swept LAST (under the application row lock), so this simulated mid-rollback
  # mint must still be caught.
  it "sweeps an edit_profile token minted from an approved device authorization during rollback" do
    application = create_cli_application(scopes: "view_profile edit_profile account")
    device_authorization = create(
      :oauth_device_authorization,
      oauth_application: application,
      scopes: "view_profile edit_profile",
      status: OauthDeviceAuthorization::STATUS_APPROVED,
      resource_owner: seller,
      approved_at: Time.current
    )

    minted_token = nil
    # Simulate the race: the poll wins just before the device-authorization
    # sweep runs, minting a token that still carries edit_profile.
    allow(migration).to receive(:revoke_scope_from_device_authorizations).and_wrap_original do |original, *args|
      _, minted_token = device_authorization.poll!(
        oauth_application: application,
        ip_address: "203.0.113.9",
        user_agent: "RSpec"
      )
      original.call(*args)
    end

    migration.down

    expect(minted_token).to be_present
    expect(minted_token.reload.scopes.to_s).to eq("view_profile")
    edit_profile_tokens = Doorkeeper::AccessToken
      .where(application_id: application.id)
      .where("scopes LIKE ?", "%edit_profile%")
    expect(edit_profile_tokens).to be_empty
  end
end
