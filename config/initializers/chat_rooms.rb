# frozen_string_literal: true

CHAT_ROOMS = {
  accounting: { slack: { channel: "accounting" } },
  announcements: { slack: { channel: "gumroad-" } },
  awards: { slack: { channel: "gumroad-awards" } },
  internals_log: { slack: { channel: "gumroad-" } },
  migrations: { slack: { channel: "gumroad-" } },
  payouts: { slack: { channel: "gumroad-" } },
  payments: { slack: { channel: "accounting" } },
  risk: { slack: { channel: "gumroad-" } },
  test: { slack: { channel: "test" } },
  iffy_log: { slack: { channel: "gumroad-iffy-log" } },
}.freeze
