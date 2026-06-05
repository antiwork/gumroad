# frozen_string_literal: true

class DeleteExpiredOauthDeviceAuthorizationsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  DELETION_BATCH_SIZE = 100

  def perform
    loop do
      ReplicaLagWatcher.watch
      rows = OauthDeviceAuthorization.expired_for_cleanup.limit(DELETION_BATCH_SIZE)
      deleted_rows = rows.delete_all
      break if deleted_rows < DELETION_BATCH_SIZE
    end
  end
end
