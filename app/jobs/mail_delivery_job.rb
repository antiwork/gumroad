# frozen_string_literal: true

# Custom ActiveJob used for all `deliver_later` email deliveries (wired up via
# `config.action_mailer.delivery_job` in config/application.rb).
#
# Sending an email means talking to an external SMTP server (SendGrid or Resend).
# Those connections occasionally fail for reasons entirely outside our
# control — the provider is briefly slow, the connection drops, or the server
# answers with a temporary "busy, try again later" response. Without this
# class, each such failure bubbles out of the job as an unhandled exception:
# Sidekiq still retries the job (so the email is eventually delivered), but
# every single attempt is also reported to Sentry as an error, producing
# thousands of alerts for failures that resolve themselves on retry.
#
# `retry_on` below handles these transient failures inside ActiveJob instead:
# the job is quietly re-enqueued with increasing backoff, and Sentry is only
# notified if all attempts are exhausted (i.e. the SMTP server has been
# unreachable for an extended period — a real problem worth alerting on).
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  # Net::OpenTimeout / Net::ReadTimeout: timeouts raised by Ruby's Net::Protocol
  # layer while opening or reading from the SMTP connection.
  #
  # Net::SMTPServerBusy: the server replied with a 4xx status (e.g. "451
  # Internal server error ... please try again later"). By the SMTP spec, 4xx
  # responses are explicitly temporary — the client is expected to retry.
  # Permanent 5xx failures raise Net::SMTPFatalError instead, which is NOT
  # listed here on purpose: retrying those can never succeed (bad recipient,
  # policy rejection), so they should surface immediately.
  retry_on Net::OpenTimeout, Net::ReadTimeout, Net::SMTPServerBusy,
           wait: :polynomially_longer, attempts: 10
end
