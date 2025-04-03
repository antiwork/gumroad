# frozen_string_literal: true

module SendableToKindle
  extend ActiveSupport::Concern

  included do
    def send_to_kindle(kindle_email)
      raise ArgumentError, "Please enter a valid Kindle email address" unless kindle_email.match(KINDLE_EMAIL_REGEX)

      CustomerMailer.send_to_kindle(kindle_email, id).deliver_later(queue: "critical")
    end
  end
end
