# frozen_string_literal: true

# Closure revoked only the mobile app's tokens before `User#revoke_all_oauth_access!`, so accounts
# closed earlier still hold live third-party access and refresh tokens, and alive subscriptions.
class Onetime::RevokeOauthAccessOfDeletedUsers
  BATCH_SIZE = 1_000

  def self.process(dry_run: true, batch_size: BATCH_SIZE)
    new(dry_run:, batch_size:).process
  end

  def initialize(dry_run:, batch_size:)
    @dry_run = dry_run
    @batch_size = batch_size
    @user_ids = Set.new
    @failed_user_ids = Set.new
  end

  def process
    revoke_for_owners_of(Doorkeeper::AccessToken.where(revoked_at: nil).where.not(resource_owner_id: nil), :resource_owner_id)
    # Only codes still inside their expiry window can be redeemed; older unrevoked grants are spent
    # or are the 60-year rows whose code is never handed out.
    revoke_for_owners_of(Doorkeeper::AccessGrant.where(revoked_at: nil).where("created_at > ?", Doorkeeper.config.authorization_code_expires_in.ago), :resource_owner_id)
    revoke_for_owners_of(ResourceSubscription.alive, :user_id)

    Rails.logger.info("[RevokeOauthAccessOfDeletedUsers] dry_run=#{@dry_run} users=#{@user_ids.size} failed=#{@failed_user_ids.to_a}")
    { user_ids: @user_ids.to_a, failed_user_ids: @failed_user_ids.to_a }
  end

  private
    def revoke_for_owners_of(scope, owner_column)
      scope.in_batches(of: @batch_size) do |batch|
        User.deleted.where(id: batch.distinct.pluck(owner_column)).find_each do |user|
          next if @user_ids.include?(user.id)

          ReplicaLagWatcher.watch unless @dry_run
          revoke(user)
        end
      end
    end

    def revoke(user)
      user.revoke_all_oauth_access! unless @dry_run
      @user_ids << user.id
      @failed_user_ids.delete(user.id)
    rescue => e
      @failed_user_ids << user.id
      Rails.logger.error("[RevokeOauthAccessOfDeletedUsers] user=#{user.id} #{e.class}: #{e.message}")
    end
end
