# frozen_string_literal: true

module User::EmailNormalization
  extend ActiveSupport::Concern

  GMAIL_DOMAINS = %w[gmail.com googlemail.com].freeze
  ABUSIVE_RISK_STATES = %w[
    suspended_for_fraud suspended_for_tos_violation
    flagged_for_fraud flagged_for_tos_violation
  ].freeze

  class_methods do
    def normalize_gmail_address(email)
      return nil if email.blank?

      local, domain = email.downcase.split("@", 2)
      return email.downcase if domain.blank?
      return email.downcase if GMAIL_DOMAINS.exclude?(domain)

      local = local.split("+", 2).first
      local = local.delete(".")
      "#{local}@gmail.com"
    end

    def abusive_gmail_variant_exists?(email)
      GmailAbuseFilter.exists?(email)
    end

    # True when a save failed because one of the signup fraud gates rejected the
    # account (blocked email domain, blocked signup IP, or a gmail variant of a
    # suspended account — all of them add a :blocked_signup error on :base with
    # the deliberately vague "Something went wrong." message). Callers that
    # rescue ActiveRecord::RecordInvalid (e.g. the OAuth signup paths) use this
    # to tell an expected fraud-gate rejection apart from a real bug, so only
    # the latter alerts Sentry.
    def blocked_signup_error?(exception)
      exception.respond_to?(:record) &&
        exception.record.present? &&
        exception.record.errors.of_kind?(:base, :blocked_signup)
    end
  end

  def add_to_gmail_abuse_filter
    GmailAbuseFilter.add!(email)
  end

  def remove_from_gmail_abuse_filter
    GmailAbuseFilter.remove!(email)
  end

  private
    def email_not_from_suspended_gmail_variant
      return if email.blank?
      return if !User.abusive_gmail_variant_exists?(email)

      errors.add(:base, :blocked_signup, message: "Something went wrong.")
    end
end
