# frozen_string_literal: true

module RescueSmtpErrors
  extend ActiveSupport::Concern

  included do
    rescue_from ArgumentError do |exception|
      if exception.message.include? "SMTP To address may not be blank"
        Rails.logger.error "Mailer Error: #{exception.inspect}"
      else
        raise exception
      end
    end

    rescue_from Net::SMTPAuthenticationError, Net::SMTPSyntaxError do |exception|
      Rails.logger.error "Mailer Error: #{exception.inspect}"
    end
  end
end
