# frozen_string_literal: true

class SuspendUsersWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  DEFAULT_SCHEDULED_PAYOUT_DELAY_DAYS = 21

  def perform(author_id, user_ids, reason, additional_notes, scheduled_payout = nil)
    author = User.find(author_id)
    author_name = author.name_or_username
    User.where(id: user_ids).or(User.where(external_id: user_ids)).find_each(batch_size: 100) do |user|
      was_suspended = user.suspended?
      content = "Suspended for a policy violation by #{author_name} on #{Time.current.to_fs(:formatted_date_full_month)} as part of mass suspension. Reason: #{reason}."
      content += "\nAdditional notes: #{additional_notes}" if additional_notes.present?
      user.suspend_for_tos_violation(author_id:, content:)

      next if was_suspended || !user.suspended?
      next if scheduled_payout.blank? || scheduled_payout["action"].blank?
      next if user.unpaid_balance_cents.to_i <= 0

      create_scheduled_payout(user, author, scheduled_payout)
    end
  end

  private
    def create_scheduled_payout(user, author, scheduled_payout)
      record = user.scheduled_payouts.create!(
        action: scheduled_payout["action"],
        delay_days: scheduled_payout["delay_days"].presence || DEFAULT_SCHEDULED_PAYOUT_DELAY_DAYS,
        payout_amount_cents: user.unpaid_balance_cents,
        created_by: author
      )

      user.comments.create!(
        author_id: author.id,
        author_name: author.name,
        comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE,
        content: "Scheduled #{record.action} for #{record.scheduled_at.to_fs(:formatted_date_full_month)} (#{record.delay_days} day delay)"
      )
    end
end
