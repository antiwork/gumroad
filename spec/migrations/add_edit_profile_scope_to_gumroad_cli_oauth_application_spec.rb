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
end
