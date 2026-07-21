# frozen_string_literal: true

# Classifies the SMTP failure reason attached to an email provider's
# bounce/blocked/dropped webhook event as either a temporary delivery problem
# (safe to retry) or a permanent one (retrying would only hurt our sender
# reputation).
#
# Context: when a send fails, SendGrid adds the address to its suppression
# list and silently drops all future mail to it. For a transient failure
# (receiving server timed out, mailbox full, greylisting, a brand-new domain
# whose MX records were still propagating) that turns a one-off hiccup into a
# permanent, invisible block — the exact failure mode that locked a brand-new
# seller out of confirming their account (gumroad-private#1210).
#
# The decision is fail-closed: anything we can't confidently match is
# :unknown, and callers must treat :unknown the same as :hard (no retry).
class TransientEmailFailureClassifier
  # Signatures of temporary failures, drawn from reason strings observed on
  # our SendGrid suppression lists. 4xx SMTP codes are temporary by
  # definition; the rest are wordings different receiving servers use for
  # "try again later" conditions.
  TRANSIENT_PATTERNS = [
    /\b4\d\d\b/,                          # any 4xx SMTP status code (421, 450, 451, 452, ...)
    /\b4\.\d+\.\d+\b/,                    # enhanced status codes in the 4.X.X class
    /timed?[ -]?out/i,                    # "connection timed out", "i/o timeout"
    /timeout/i,                           # "error dialing remote address: dial tcp ... i/o timeout"
    /try again later/i,                   # classic greylisting wording
    /greylist/i,
    /temporar/i,                          # "temporarily deferred", "temporary failure", "resources temporarily unavailable"
    /connection refused/i,                # receiving server was unreachable at send time
    /mailbox (is )?full/i,                # 452/552 mailbox full — the mailbox exists, it's just full
    /over quota/i,
    /resources unavailable/i,
  ].freeze

  # Signatures of permanent failures. Retrying these damages sender
  # reputation and can never succeed — the address or domain itself is bad.
  HARD_PATTERNS = [
    /user unknown/i,
    /no such (user|mailbox|recipient)/i,
    /does not exist/i,
    /\b5\.1\.1\b/,                        # "550 5.1.1" = bad destination mailbox address
    /unknown (user|recipient|address)/i,
    /(domain|host).{0,30}not found/i,     # NXDOMAIN-style: the domain doesn't resolve
    /nxdomain/i,
    /\b553\b/,                            # 553 = bad mailbox name / syntactically invalid address
    /bad mailbox name/i,
    /not configured to receive/i,         # alias/Proton mailboxes not set up for receiving
    /recipient address rejected/i,
    /invalid recipient/i,
  ].freeze

  def initialize(event_type:, reason:)
    @event_type = event_type
    @reason = reason.to_s
  end

  # Returns :transient, :hard, or :unknown. Hard signatures win over
  # transient ones, so a reason like "550 5.1.1 user unknown (try again
  # later?)" can never be retried by accident.
  def classify
    return :unknown if @reason.blank?
    return :hard if HARD_PATTERNS.any? { |pattern| @reason.match?(pattern) }
    return :transient if TRANSIENT_PATTERNS.any? { |pattern| @reason.match?(pattern) }

    :unknown
  end

  def transient?
    classify == :transient
  end
end
