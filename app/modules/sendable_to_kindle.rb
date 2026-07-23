# frozen_string_literal: true

module SendableToKindle
  extend ActiveSupport::Concern

  included do
    # `url_redirect` provides the purchase context needed to locate the
    # buyer-specific stamped copy of a stamp-enabled PDF. Without it the
    # original (un-watermarked) file would be emailed, bypassing the
    # seller's PDF stamping setting.
    def send_to_kindle(kindle_email, url_redirect: nil)
      raise ArgumentError, "Please enter a valid Kindle email address" unless kindle_email.match(KINDLE_EMAIL_REGEX)

      CustomerMailer.send_to_kindle(kindle_email, id, url_redirect&.id).deliver_later(queue: "critical")
    end
  end
end
