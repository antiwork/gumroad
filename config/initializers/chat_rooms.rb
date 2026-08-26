# frozen_string_literal: true

# Risk / ops / announcements: Gumclaw inbox only. Never hi@ (Sahil, 2026-08-25).
INTERNAL_NOTIFICATION_EMAIL = GlobalConfig.get("INTERNAL_NOTIFICATION_EMAIL", "gumclaw@gumroad.com")
# Finance reports + payments/payouts alerts: finance@, plus ALWAYS_CC gumclaw.
PAYMENTS_NOTIFICATION_EMAIL = GlobalConfig.get("PAYMENTS_NOTIFICATION_EMAIL", "finance@gumroad.com")

# Address CC'd on EVERY internal notification (all CHAT_ROOMS), in addition to each
# room's own recipient. Risk/ops rooms now default to this same inbox (never hi@);
# payments/payouts still go to finance@ with this CC.
INTERNAL_NOTIFICATION_ALWAYS_CC = GlobalConfig.get("INTERNAL_NOTIFICATION_ALWAYS_CC", "gumclaw@gumroad.com")

CHAT_ROOMS = {
  # Reports the agent already works autonomously (gumroad-private#2106): delivered to the
  # agent inbox only, so the finding stays recorded without pushing mail at a human.
  agent_reports: { email: INTERNAL_NOTIFICATION_ALWAYS_CC },
  announcements: { email: INTERNAL_NOTIFICATION_EMAIL },
  awards: { email: INTERNAL_NOTIFICATION_EMAIL },
  internals_log: { email: INTERNAL_NOTIFICATION_EMAIL },
  migrations: { email: INTERNAL_NOTIFICATION_EMAIL },
  payments: { email: PAYMENTS_NOTIFICATION_EMAIL },
  payouts: { email: PAYMENTS_NOTIFICATION_EMAIL },
  risk: { email: INTERNAL_NOTIFICATION_EMAIL },
  test: { email: INTERNAL_NOTIFICATION_EMAIL },
}.freeze
