# frozen_string_literal: true

# Custom ActiveJob used for all `deliver_later` email deliveries (wired up via
# `config.action_mailer.delivery_job` in config/application.rb).
#
# Sending an email means talking to an external SMTP server (SendGrid or Resend).
# Those connections occasionally time out for reasons entirely outside our
# control — the provider is briefly slow or the connection drops. Without this
# class, each timeout bubbles out of the job as an unhandled exception: Sidekiq
# still retries the job (so the email is eventually delivered), but every single
# attempt is also reported to Sentry as an error, producing thousands of alerts
# for failures that resolve themselves on retry.
#
# `retry_on` below handles these transient network timeouts inside ActiveJob
# instead: the job is quietly re-enqueued with increasing backoff, and Sentry is
# only notified if all attempts are exhausted (i.e. the SMTP server has been
# unreachable for an extended period — a real problem worth alerting on).
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  # Timeouts raised by Ruby's Net::Protocol layer while opening or reading from
  # the SMTP connection. These are transient by nature — retrying is the fix.
  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 10
end
