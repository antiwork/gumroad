# frozen_string_literal: true

# Daily log-only scan: records what the social score would have done for each
# held payout. The release path stays human until the false-release rate
# measured from these rows is acceptable.
#
# The population starts from social_connect_verifications rather than from
# held sellers: holds live in an unindexed flags bit plus the risk-state
# column, while the verifications table is small and indexed, and a seller
# with no verification scores zero by definition.
class RecordSocialScoreShadowEvaluationsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed, retry: 2
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 30.minutes

  BATCH_SIZE = 500

  def perform
    evaluated_on = Time.current.to_date
    failed_user_ids = []

    SocialConnectVerification.distinct.pluck(:user_id).each_slice(BATCH_SIZE) do |user_ids|
      ReplicaLagWatcher.watch

      User.where(id: user_ids).find_each do |user|
        evaluation = SocialScoreShadowEvaluationService.new(user).evaluate
        next if evaluation.nil?

        record = SocialScoreShadowEvaluation.find_or_initialize_by(user:, evaluated_on:)
        record.update!(evaluation)
      rescue => e
        failed_user_ids << user.id
        Rails.logger.error("RecordSocialScoreShadowEvaluationsJob failed for user #{user.id}: #{e.class}: #{e.message}")
      end
    end

    # Re-raise after the full pass so Sidekiq retries the failed sellers;
    # completed rows are idempotent per (user, day), so the retry is safe.
    raise "RecordSocialScoreShadowEvaluationsJob failed for #{failed_user_ids.size} users: #{failed_user_ids.first(20).inspect}" if failed_user_ids.any?
  end
end
