# frozen_string_literal: true

# Retries a single ESP API call through a connection-establishment blip.
#
# Wrap ONLY the provider request itself. Anything wider — a whole blast slice, or a
# provider call plus its bookkeeping — can have already handed recipients to one ESP
# before the failure, and retrying that re-sends them.
#
# Deliberately narrow on which errors qualify:
#
#   * Only failures raised while OPENING the connection. Those provably happened before
#     the request reached the ESP, so a retry cannot duplicate a send. `Errno::ECONNRESET`
#     and `Net::ReadTimeout` are excluded for exactly that reason — they can fire after
#     the ESP accepted the payload, and a retry would send it twice.
#   * A rejected payload (`ResendApiResponseError`, a SendGrid 4xx) raises straight
#     through: the identical payload will be rejected again, so retrying only delays the
#     real failure and hides it from Sidekiq's own retry.
#
# The observed production failures (gp#1750) are all in the safe set:
# `Socket::ResolutionError: Failed to open TCP connection to api.resend.com:443`.
module TransientDeliveryRetry
  ATTEMPTS = 4
  BACKOFF = [2, 8, 30].freeze
  RETRIABLE_ERRORS = [
    Socket::ResolutionError,
    Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH,
    Errno::ETIMEDOUT,
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
      sleep(BACKOFF[attempt - 1])
      retry
    end
  end
end
