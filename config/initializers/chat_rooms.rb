# frozen_string_literal: true

INTERNAL_NOTIFICATION_EMAIL = GlobalConfig.get("INTERNAL_NOTIFICATION_EMAIL", "hi@gumroad.com")
PAYMENTS_NOTIFICATION_EMAIL = GlobalConfig.get("PAYMENTS_NOTIFICATION_EMAIL", "hi@gumroad.com")

# Optional address CC'd on every internal notification. This is intentionally
# disabled by default: internal notifications can include sensitive risk,
# payments, and payouts data, so a broad secondary recipient must be enabled
# explicitly via configuration rather than hard-coded in source.
INTERNAL_NOTIFICATION_ALWAYS_CC = GlobalConfig.get("INTERNAL_NOTIFICATION_ALWAYS_CC", nil)

CHAT_ROOMS = {
  announcements: { email: INTERNAL_NOTIFICATION_EMAIL },
  awards: { email: INTERNAL_NOTIFICATION_EMAIL },
  internals_log: { email: INTERNAL_NOTIFICATION_EMAIL },
  migrations: { email: INTERNAL_NOTIFICATION_EMAIL },
  payments: { email: PAYMENTS_NOTIFICATION_EMAIL },
  payouts: { email: PAYMENTS_NOTIFICATION_EMAIL },
  risk: { email: INTERNAL_NOTIFICATION_EMAIL },
  test: { email: INTERNAL_NOTIFICATION_EMAIL },
}.freeze
