# frozen_string_literal: true

INTERNAL_NOTIFICATION_EMAIL = ENV.fetch("INTERNAL_NOTIFICATION_EMAIL", "hi@gumroad.com")

CHAT_ROOMS = {
  accounting: { email: INTERNAL_NOTIFICATION_EMAIL },
  announcements: { email: INTERNAL_NOTIFICATION_EMAIL },
  awards: { email: INTERNAL_NOTIFICATION_EMAIL },
  internals_log: { email: INTERNAL_NOTIFICATION_EMAIL },
  migrations: { email: INTERNAL_NOTIFICATION_EMAIL },
  payouts: { email: INTERNAL_NOTIFICATION_EMAIL },
  payments: { email: INTERNAL_NOTIFICATION_EMAIL },
  risk: { email: INTERNAL_NOTIFICATION_EMAIL },
  test: { email: INTERNAL_NOTIFICATION_EMAIL },
  iffy_log: { email: INTERNAL_NOTIFICATION_EMAIL },
}.freeze
