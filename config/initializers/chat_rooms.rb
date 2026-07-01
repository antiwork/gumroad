# frozen_string_literal: true

INTERNAL_NOTIFICATION_EMAIL = GlobalConfig.get("INTERNAL_NOTIFICATION_EMAIL", "hi@gumroad.com")
PAYMENTS_NOTIFICATION_EMAIL = GlobalConfig.get("PAYMENTS_NOTIFICATION_EMAIL", "hi@gumroad.com")

# Address CC'd on EVERY internal notification (all CHAT_ROOMS), in addition to each
# room's own recipient. Lets Gumclaw ingest the full internal-notification stream
# (risk alerts, payments, payouts, etc.) alongside the existing human recipients.
INTERNAL_NOTIFICATION_ALWAYS_CC = GlobalConfig.get("INTERNAL_NOTIFICATION_ALWAYS_CC", "gumclaw@gumroad.com")

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
