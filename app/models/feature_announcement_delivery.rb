# frozen_string_literal: true

# The final gate for FeatureAnnouncementMailer: one row per campaign and user (and address),
# committed before the provider handoff. `claimed` and `unknown` rows are quarantined and never
# resent automatically, which bounds each recipient to one attempt but is not exactly-once.
class FeatureAnnouncementDelivery < ApplicationRecord
  STATES = %w[claimed delivered skipped rejected failed unknown].freeze
  QUARANTINED_STATES = %w[claimed unknown].freeze
  LOCK_WAIT_SECONDS = 5
  # Caps the whole SMTP exchange, which runs while the gate holds row locks. Net::SMTP has no
  # write timeout setting, so its socket writes otherwise wait up to Net::Protocol's 60s.
  HANDOFF_TIMEOUT_SECONDS = 30
  ONE_CLICK = "List-Unsubscribe=One-Click"

  # The provider did not accept the message (a 4xx is a definite refusal), so the claim is
  # released and MailDeliveryJob's retry_on retries it.
  RETRYABLE_ERRORS = [Net::OpenTimeout, Net::SMTPServerBusy].freeze
  REJECTED_ERRORS = [Net::SMTPFatalError, Net::SMTPSyntaxError].freeze
  # Also not accepted, but RescueSmtpErrors swallows it, so no retry would come: keep a row.
  FAILED_ERRORS = [Net::SMTPAuthenticationError].freeze

  class AmbientTransactionError < StandardError; end
  class UnsafeMailSettingsError < StandardError; end
  class HandoffTimeout < Timeout::Error; end

  belongs_to :user, optional: true

  validates :state, inclusion: { in: STATES }

  scope :quarantined, -> { where(state: QUARANTINED_STATES) }

  def self.hand_off(message, &smtp)
    target = message.try(:feature_announcement_target)
    if target.nil?
      Rails.logger.error("[FeatureAnnouncementDelivery] Refused a message with no handoff target")
      return
    end

    # deliver! ignores perform_deliveries, and with raise_delivery_errors off Mail swallows SMTP
    # errors after we record them, so neither can be trusted to mean what the claim would say.
    unless message.perform_deliveries && message.raise_delivery_errors
      Rails.logger.error("[FeatureAnnouncementDelivery] Refused: perform_deliveries or raise_delivery_errors is off")
      raise UnsafeMailSettingsError, "Feature announcements need perform_deliveries and raise_delivery_errors on"
    end

    ApplicationRecord.connected_to(role: :writing) do
      # Inside a caller's transaction the claim would only commit with it, so a rollback after
      # the provider accepted the message would erase the record that stops a resend.
      raise AmbientTransactionError, "Deliver feature announcements outside a transaction" if connection.current_transaction.joinable?

      claim_for(target)&.send_if_eligible(message, &smtp)
    end
  end

  def self.claim_for(target)
    create!(campaign: target[:campaign], user_id: target[:user_id], email: canonical_email(target[:email]), state: "claimed")
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[FeatureAnnouncementDelivery] #{target[:campaign]} already claimed for user #{target[:user_id]} or their address")
    nil
  end

  def self.canonical_email(email)
    email.to_s.strip.downcase
  end

  # The campaign, account status, address and consent are read under share locks, so a writer either
  # commits before the check or waits for the handoff. The audience is read after those waits, uncached
  # and as this transaction's first plain read, so a product, sale or payout change made meanwhile counts.
  def send_if_eligible(message, &block)
    handing_off = false
    with_bounded_lock_wait do
      transaction do
        lock!
        user = User.lock("FOR SHARE").find_by(id: user_id)
        subscription = FeatureAnnouncementSubscription.lock("FOR SHARE").find_by(user_id:)
        @content = FeatureAnnouncementCampaign.lock("FOR SHARE").find_by(key: campaign)
        reason = ineligibility_reason(message, user, subscription) || ("not_in_audience" unless self.class.uncached { in_audience?(user) })
        if reason
          update!(state: "skipped", reason:)
        else
          handing_off = true
          Timeout.timeout(HANDOFF_TIMEOUT_SECONDS, HandoffTimeout, &block)
          update!(state: "delivered")
        end
      end
    end
  rescue StandardError => e
    if !handing_off || RETRYABLE_ERRORS.any? { e.is_a?(_1) }
      self.class.where(id:, state: "claimed").delete_all
      raise
    elsif REJECTED_ERRORS.any? { e.is_a?(_1) }
      self.class.where(id:).update_all(state: "rejected", reason: e.class.name.first(64), updated_at: Time.current)
      raise
    elsif FAILED_ERRORS.any? { e.is_a?(_1) }
      self.class.where(id:).update_all(state: "failed", reason: e.class.name.first(64), updated_at: Time.current)
      ErrorNotifier.notify(e, context: { feature_announcement_delivery_id: id })
      raise
    else
      # Raising would let MailDeliveryJob retry, and the provider may already have the message.
      self.class.where(id:).update_all(state: "unknown", reason: e.class.name.first(64), updated_at: Time.current)
      ErrorNotifier.notify(e, context: { feature_announcement_delivery_id: id })
    end
  end

  private
    def in_audience?(user)
      FeatureAnnouncementMailer.in_audience?(content, user)
    end

    attr_reader :content

    def ineligibility_reason(message, user, subscription)
      return "unknown_campaign" if content.nil?
      return "campaign_not_deliverable" unless content.deliverable?
      return "user_missing" if user.nil?
      return "account_inactive" unless user.account_active?
      return "email_unconfirmed" unless user.confirmed?
      # A pending change makes the preferred address ambiguous, so neither is used.
      return "email_change_pending" if user.unconfirmed_email.present?
      return "recipient_mismatch" unless message.destinations.map { self.class.canonical_email(_1) } == [email] &&
                                         self.class.canonical_email(user.email) == email
      return "not_subscribed" unless subscription&.subscribed?
      return "content_mismatch" unless message.feature_announcement_target[:content_digest] == content.content_digest &&
                                       message.subject == content.subject &&
                                       message[:from].to_s == FeatureAnnouncementMailer::FROM &&
                                       message.reply_to == [content.reply_to]
      "unsubscribe_link_mismatch" unless unsubscribe_link_matches?(message)
    end

    def unsubscribe_link_matches?(message)
      return false unless message["List-Unsubscribe-Post"]&.value == ONE_CLICK

      url = message["List-Unsubscribe"]&.value.to_s[/\A<(.+)>\z/, 1]
      token = url && URI.parse(url).path.split("/").last
      FeatureAnnouncementSubscription.decode_unsubscribe_token(token) ==
        [user_id, FeatureAnnouncementSubscription.address_digest(email)]
    rescue URI::InvalidURIError
      false
    end

    def with_bounded_lock_wait
      connection = self.class.connection
      previous = connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")
      connection.execute("SET SESSION innodb_lock_wait_timeout = #{LOCK_WAIT_SECONDS}")
      yield
    ensure
      connection.execute("SET SESSION innodb_lock_wait_timeout = #{previous.to_i}") if connection && previous.present?
    end
end
