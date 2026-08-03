# frozen_string_literal: true

# Retries a single ESP API call through a connection-establishment blip.
#
# Wrap ONLY the provider request itself. Anything wider — a whole blast slice, or a
# provider call plus its bookkeeping — can have already handed recipients to one ESP
# before the failure, and retrying that re-sends them.
#
# Deliberately narrow on which errors qualify:
#
#   * Only errors that can ONLY be raised while opening the connection, so a retry cannot
#     duplicate a send. `Errno::ECONNRESET` and `Net::ReadTimeout` are excluded because they
#     can fire after the ESP accepted the payload. So are `Errno::EHOSTUNREACH` and
#     `Errno::ETIMEDOUT`: those are raw syscall errors that the response-read can raise just
#     as well as the connect can (an ICMP unreachable during a routing flap), and the rescue
#     cannot tell the two phases apart.
#   * A rejected payload (`ResendApiResponseError`, a SendGrid 4xx) raises straight
#     through: the identical payload will be rejected again, so retrying only delays the
#     real failure and hides it from Sidekiq's own retry.
#
# The observed production failures (gp#1750) are all in the safe set:
# `Socket::ResolutionError: Failed to open TCP connection to api.resend.com:443`.
module TransientDeliveryRetry
  # Total backoff must stay under Sidekiq's shutdown grace period (~25s). A hard kill
  # mid-sleep raises Sidekiq::Shutdown, which is an Interrupt rather than a StandardError,
  # so it slips past the caller's `rescue => e` cleanup and leaves SentPostEmail rows
  # behind for recipients that were never actually sent — they are then filtered out of
  # the retry as already-emailed. 2+8 = 10s of cover, well inside the grace period.
  BACKOFF = [2, 8].freeze
  ATTEMPTS = BACKOFF.size + 1
  RETRIABLE_ERRORS = [
    Socket::ResolutionError,
    Errno::ECONNREFUSED,
    Net::OpenTimeout,
  ].freeze

  def self.call(context:)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue *RETRIABLE_ERRORS => e
      raise e if attempt >= ATTEMPTS

      Rails.logger.info(
        "[TransientDeliveryRetry] #{context} transient connection error on attempt #{attempt} " \
        "(#{e.class}: #{e.message}), retrying")
      sleep(BACKOFF.fetch(attempt - 1, BACKOFF.last))
      retry
    end
  end
end
