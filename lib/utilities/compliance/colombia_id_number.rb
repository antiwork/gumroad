# frozen_string_literal: true

# Stripe enforces 7-10 digits on individual.id_number for Colombia (support case
# sco_UyXAayCkurHzCd). Colombia's own document spec allows 6 digits, so the floor excludes Cédula
# de Extranjería numbers that legitimately exist — Stripe have raised that with their product team,
# and this range should be widened if they change it. Test-mode Stripe does NOT enforce the rule, so
# a local probe cannot re-derive these bounds. Browser copy: app/javascript/utils/colombiaIdNumbers.ts.
# Widening DIGIT_RANGE also means editing the Colombia section of
# app/views/help_center/articles/contents/_260-your-payout-settings-page.html.erb, which states the
# bound to sellers — the help center cannot interpolate this constant.
module Compliance
  module ColombiaIdNumber
    DIGIT_RANGE = (7..10)

    # Sellers paste the number with the thousands separators printed on the document. Stripe refuses
    # those, and the length check counts digits, so callers must send what was counted — otherwise a
    # value that passes the guard reaches Stripe longer than the guard measured.
    def self.normalize(value)
      value.to_s.gsub(/\D/, "")
    end

    def self.valid?(value)
      DIGIT_RANGE.cover?(normalize(value).length)
    end

    # Names both documents rather than "your ID", so a foreign resident can tell the message is about
    # the document they actually hold. Zero-padding is called out because it is the workaround sellers
    # reach for on their own, and it trades today's block for an id_number_match verification failure
    # later, once they have a balance.
    ERROR_MESSAGE = "Your Cédula de Ciudadanía or Cédula de Extranjería must be " \
                    "#{DIGIT_RANGE.first}-#{DIGIT_RANGE.last} digits. Enter it exactly as it appears " \
                    "on your document — do not add leading zeros, as the number has to match the " \
                    "document you may later be asked to upload."
  end
end
