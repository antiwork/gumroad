# frozen_string_literal: true

# Daily shadow-mode scan (gumroad-private#2371, slice 2): for every seller who
# has a verified social connection AND a currently-held payout balance, record
# what the social score was and whether it would have released the hold. Log
# only — the release path stays human until the false-release rate measured
# from these rows is acceptable.
#
# The population starts from social_connect_verifications rather than from
# held sellers: holds live in an unindexed flags bit plus the risk-state
# column, while the verifications table is small and indexed, and a seller
# with no verification scores zero by definition — recording those rows daily
# would add volume, not evidence.
class RecordSocialScoreShadowEvaluationsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed, retry: 2
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 30.minutes

  BATCH_SIZE = 500

  def perform
    evaluated_on = Time.current.to_date

    SocialConnectVerification.distinct.pluck(:user_id).each_slice(BATCH_SIZE) do |user_ids|
      ReplicaLagWatcher.watch

      User.where(id: user_ids).find_each do |user|
        evaluation = SocialScoreShadowEvaluationService.new(user).evaluate
        next if evaluation.nil?

        record = SocialScoreShadowEvaluation.find_or_initialize_by(user:, evaluated_on:)
        record.update!(evaluation)
      rescue => e
        Rails.logger.error("RecordSocialScoreShadowEvaluationsJob failed for user #{user.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
