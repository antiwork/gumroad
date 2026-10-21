# frozen_string_literal: true

require "spec_helper"

describe OauthApplication, "contending for the application row" do
  self.use_transactional_tests = false

  before do
    allow_any_instance_of(described_class).to receive(:sleep)
    stub_const("OauthApplication::LOCK_WAIT_SECONDS", 1)
    @owner = create(:user)
    @user = create(:user)
    @oauth_application = create(:oauth_application, owner: @owner)
  end

  after do
    Doorkeeper::AccessToken.where(application_id: @oauth_application.id).delete_all
    @oauth_application.delete
    [@user, @owner].each(&:destroy!)
    delete_leftovers(user_ids: [@user.id, @owner.id])
  end

  def held_application(shared:)
    -> { OauthApplication.find(@oauth_application.id).with_application_lock(shared:) { true } }
  end

  it "takes a shared lock without waiting for another shared holder" do
    while_held_elsewhere(held_application(shared: true)) do
      result = Timeout.timeout(10) { @oauth_application.with_application_lock(shared: true) { :signed_in } }

      expect(result).to eq(:signed_in)
    end
  end

  it "makes an exclusive lock wait for a shared holder" do
    while_held_elsewhere(held_application(shared: true)) do
      expect do
        @oauth_application.with_application_lock { :swept }
      end.to raise_error(OauthApplication::LockUnavailable)
    end
  end

  it "makes a shared lock wait for an exclusive holder" do
    while_held_elsewhere(held_application(shared: false)) do
      expect do
        @oauth_application.with_application_lock(shared: true) { :signed_in }
      end.to raise_error(OauthApplication::LockUnavailable)
    end
  end

  it "revokes one user's tokens without excluding another shared holder" do
    create("doorkeeper/access_token", application: @oauth_application, resource_owner_id: @user.id, scopes: "edit_products")

    while_held_elsewhere(-> { OauthApplication.find(@oauth_application.id).revoke_access_tokens_for(@user) }) do
      result = Timeout.timeout(10) { @oauth_application.with_application_lock(shared: true) { :signed_in } }

      expect(result).to eq(:signed_in)
    end
  end
end
