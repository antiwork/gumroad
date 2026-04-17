# frozen_string_literal: true

class SuspendUsersWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  DEFAULT_SCHEDULED_PAYOUT_DELAY_DAYS = 21

  def perform(author_id, user_ids, reason, additional_notes, scheduled_payout = nil)
    author = User.find(author_id)
    author_name = author.name_or_username
    has_scheduled_payout_params = scheduled_payout.present? && scheduled_payout["action"].present?
    User.where(id: user_ids).or(User.where(external_id: user_ids)).find_each(batch_size: 100) do |user|
      was_suspended = user.suspended?
      content = "Suspended for a policy violation by #{author_name} on #{Time.current.to_fs(:formatted_date_full_month)} as part of mass suspension. Reason: #{reason}."
      content += "\nAdditional notes: #{additional_notes}" if additional_notes.present?
      # When we intend to create a scheduled payout in this flow we defer the
      # suspension email until *after* the record exists, so the mailer can be
      # given that exact scheduled payout id and will not pick up an unrelated
      # `.pending.last` record for this user.
      user.suspend_for_tos_violation(
        author_id:,
        content:,
        skip_generic_suspension_email: has_scheduled_payout_params
      )

      next if was_suspended || !user.suspended?
      next unless has_scheduled_payout_params
      next if user.unpaid_balance_cents.to_i <= 0

      record = create_scheduled_payout(user, author, scheduled_payout)
      if Feature.active?(:account_suspended_email)
        ContactingCreatorMailer.account_suspended(user.id, record&.id).deliver_later
      end
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

      record
    end
end
