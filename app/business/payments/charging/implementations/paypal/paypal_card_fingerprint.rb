# frozen_string_literal: true

module PaypalCardFingerprint
  PAYPAL_FINGERPRINT_PREFIX = "paypal_"
  private_constant :PAYPAL_FINGERPRINT_PREFIX

  def self.build_paypal_fingerprint(email)
    return "#{PAYPAL_FINGERPRINT_PREFIX}#{email}" if email.present?

    nil
  end
end
