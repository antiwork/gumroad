# frozen_string_literal: true

require "spec_helper"

describe Onetime::RevokeOauthAccessOfDeletedUsers do
  describe ".process" do
    let(:oauth_application) { create(:oauth_application) }
    let(:deleted_user) { create(:user, deleted_at: 1.year.ago) }
    let(:alive_user) { create(:user) }
    let!(:deleted_user_token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: deleted_user.id, scopes: "view_sales", use_refresh_token: true) }
    let!(:alive_user_token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: alive_user.id, scopes: "view_sales") }

    it "reports the deleted users without revoking anything in a dry run" do
      expect(ReplicaLagWatcher).not_to receive(:watch)

      expect(described_class.process).to eq(user_ids: [deleted_user.id], failed_user_ids: [])

      expect(deleted_user_token.reload).not_to be_revoked
    end

    it "revokes the access of deleted users only" do
      resource_subscription = create(:resource_subscription, oauth_application:, user: deleted_user)
      alive_user_subscription = create(:resource_subscription, oauth_application:, user: alive_user)

      expect(described_class.process(dry_run: false, batch_size: 1)).to eq(user_ids: [deleted_user.id], failed_user_ids: [])

      expect(deleted_user_token.reload).to be_revoked
      expect(resource_subscription.reload).to be_deleted
      expect(alive_user_token.reload).not_to be_revoked
      expect(alive_user_subscription.reload).not_to be_deleted
    end

    it "deletes the subscriptions of a deleted user who holds no live token" do
      user_without_token = create(:user, deleted_at: 1.year.ago)
      resource_subscription = create(:resource_subscription, oauth_application:, user: user_without_token)

      result = described_class.process(dry_run: false)

      expect(result[:user_ids]).to contain_exactly(deleted_user.id, user_without_token.id)
      expect(resource_subscription.reload).to be_deleted
    end

    it "revokes a redeemable authorization code of a deleted user who holds no live token" do
      user_with_code = create(:user, deleted_at: 1.minute.ago)
      user_with_expired_code = create(:user, deleted_at: 1.year.ago)
      access_grant = Doorkeeper::AccessGrant.create!(application_id: oauth_application.id, resource_owner_id: user_with_code.id, redirect_uri: oauth_application.redirect_uri,
                                                     expires_in: Doorkeeper.config.authorization_code_expires_in.to_i, scopes: "view_sales")
      expired_grant = Doorkeeper::AccessGrant.create!(application_id: oauth_application.id, resource_owner_id: user_with_expired_code.id, redirect_uri: oauth_application.redirect_uri,
                                                      expires_in: Doorkeeper.config.authorization_code_expires_in.to_i, scopes: "view_sales", created_at: 1.year.ago)

      result = described_class.process(dry_run: false)

      expect(result[:user_ids]).to contain_exactly(deleted_user.id, user_with_code.id)
      expect(access_grant.reload).to be_revoked
      expect(expired_grant.reload).not_to be_revoked
    end

    it "continues past a user whose revocation fails" do
      other_deleted_user = create(:user, deleted_at: 1.year.ago)
      other_token = create("doorkeeper/access_token", application: oauth_application, resource_owner_id: other_deleted_user.id, scopes: "view_sales")
      allow_any_instance_of(User).to receive(:revoke_all_oauth_access!).and_wrap_original do |original, *args|
        raise ActiveRecord::LockWaitTimeout if original.receiver.id == deleted_user.id
        original.call(*args)
      end

      result = described_class.process(dry_run: false)

      expect(result).to eq(user_ids: [other_deleted_user.id], failed_user_ids: [deleted_user.id])
      expect(other_token.reload).to be_revoked
    end
  end
end
