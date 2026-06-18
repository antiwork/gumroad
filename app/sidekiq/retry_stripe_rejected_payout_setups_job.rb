# frozen_string_literal: true

class RetryStripeRejectedPayoutSetupsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  MAX_RETRIES = 6
  RETRY_BACKOFF_DAYS = [1, 1, 2, 3, 4, 4].freeze

  BATCH_SIZE = 1_000

  def perform
    candidate_notes.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      ReplicaLagWatcher.watch
      batch.filter_map { |note| note.commentable_id if self.class.due_for_processing?(note) }
           .uniq
           .each { |user_id| RetryStripeRejectedPayoutSetupForSellerJob.perform_async(user_id) }
    end
  end

  def self.retry_count(note)
    note.json_data["retry_count"].to_i
  end

  def self.due_for_processing?(note)
    return false if note.json_data["abandoned_at"].present?
    return true if retry_count(note) >= MAX_RETRIES

    last_retried_at = note.json_data["last_retried_at"]
    return true if last_retried_at.blank?

    backoff = RETRY_BACKOFF_DAYS.fetch(retry_count(note), RETRY_BACKOFF_DAYS.last)
    Time.iso8601(last_retried_at) + backoff.days <= Time.current
  rescue ArgumentError
    true
  end

  private
    def candidate_notes
      Comment.alive
             .with_type_payout_note
             .where(commentable_type: "User", author_id: GUMROAD_ADMIN_ID)
             .where(
               "content LIKE ? OR content LIKE ?",
               "#{StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX}%",
               "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}%"
             )
    end
end
