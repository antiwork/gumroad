# frozen_string_literal: true

require "spec_helper"

# mark_deleted! revokes an application's grants and tokens under its row lock. Without an
# application_id index those updates scan the whole table and queue behind any row another
# transaction holds.
describe OauthApplication, "sweeping credentials on delete" do
  self.use_transactional_tests = false

  before do
    allow_any_instance_of(described_class).to receive(:sleep)
    stub_const("OauthApplication::LOCK_WAIT_SECONDS", 1)
    @owner = create(:user)
    @user = create(:user)
    @deleted_application = create(:oauth_application, owner: @owner)
    @other_application = create(:oauth_application, owner: @owner)
  end

  after do
    application_ids = [@deleted_application.id, @other_application.id]
    Doorkeeper::AccessGrant.where(application_id: application_ids).delete_all
    Doorkeeper::AccessToken.where(application_id: application_ids).delete_all
    OauthApplication.where(id: application_ids).delete_all
    [@user, @owner].each(&:destroy!)
    delete_leftovers(user_ids: [@user.id, @owner.id])
  end

  def create_grant(application)
    Doorkeeper::AccessGrant.create!(application:, resource_owner_id: @user.id, scopes: "edit_products", redirect_uri: application.redirect_uri, expires_in: 10.minutes)
  end

  def held_row(record)
    -> { record.class.lock.find(record.id) }
  end

  it "does not wait on another application's live token" do
    create("doorkeeper/access_token", application: @deleted_application, resource_owner_id: @user.id, scopes: "edit_products")
    other_token = create("doorkeeper/access_token", application: @other_application, resource_owner_id: @user.id, scopes: "edit_products")

    while_held_elsewhere(held_row(other_token)) do
      Timeout.timeout(10) { @deleted_application.mark_deleted! }

      expect(@deleted_application.reload).to be_deleted
      expect(@deleted_application.access_tokens.where(revoked_at: nil)).to be_empty
      expect(other_token.reload.revoked_at).to be_nil
    end
  end

  it "does not wait on another application's live grant" do
    create_grant(@deleted_application)
    other_grant = create_grant(@other_application)

    while_held_elsewhere(held_row(other_grant)) do
      Timeout.timeout(10) { @deleted_application.mark_deleted! }

      expect(@deleted_application.reload).to be_deleted
      expect(@deleted_application.access_grants.where(revoked_at: nil)).to be_empty
      expect(other_grant.reload.revoked_at).to be_nil
    end
  end
end
