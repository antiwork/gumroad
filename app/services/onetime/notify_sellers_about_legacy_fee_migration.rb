# frozen_string_literal: true

class Onetime::NotifySellersAboutLegacyFeeMigration < Onetime::Base
  LAST_PROCESSED_USER_ID_KEY = "notify_sellers_legacy_fee_migration_last_user_id"
  SUBJECT = "Heads up: Your Gumroad fees are changing"
  BODY = <<~HTML
    <p>In 2023, Gumroad moved to a flat 10% + $0.50 per transaction for all creators. Your membership products created before the transition have remained on an older rate.</p>
    <p>Starting today, those memberships will move to the same pricing as everything else on Gumroad.</p>
    <p>You can see the full details at <a href="https://gumroad.com/pricing">gumroad.com/pricing</a>.</p>
    <p>If you have any questions, just reply to this email.</p>
    <p>The Gumroad Team</p>
  HTML

  attr_reader :seller_ids, :emailed_user_ids

  def self.reset_last_processed_user_id
    $redis.del(LAST_PROCESSED_USER_ID_KEY)
  end

  def initialize(seller_ids:)
    @seller_ids = seller_ids.map(&:to_i).uniq.sort
    @emailed_user_ids = []
  end

  def process
    last_processed_id = $redis.get(LAST_PROCESSED_USER_ID_KEY).to_i

    User.where(id: seller_ids).alive.not_suspended.where("users.id > ?", last_processed_id).find_each do |user|
      if user.form_email.present?
        OneOffMailer.email(
          email: user.form_email,
          subject: SUBJECT,
          body: BODY,
          reply_to: ApplicationMailer::SUPPORT_EMAIL
        ).deliver_later(queue: "low")

        @emailed_user_ids << user.id
        Rails.logger.info "Enqueued legacy fee migration email for user #{user.id}"
      end

      $redis.set(LAST_PROCESSED_USER_ID_KEY, user.id)
    end

    Rails.logger.info "Total emails enqueued: #{emailed_user_ids.size}"
    emailed_user_ids
  end
end
