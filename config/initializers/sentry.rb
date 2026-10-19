# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = GlobalConfig.get("SENTRY_DSN")
  config.enabled_environments = %w[production staging]
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.send_default_pii = true
  config.traces_sample_rate = 0.001
  config.excluded_exceptions += [
    "ActionController::RoutingError",
    "ActionController::InvalidAuthenticityToken",
    "AbstractController::ActionNotFound",
    "ActionController::UnknownFormat",
    "ActionController::UnknownHttpMethod",
    "ActionController::BadRequest",
    "Mime::Type::InvalidMimeType",
    "ActionController::ParameterMissing",
  ]

  # Installed Gumhead apps still post prompts and the seller's bearer token to
  # the retired /v2/gumhead routes. With send_default_pii on, Sentry would keep
  # both, so drop every event for those URLs.
  retired_gumhead_request = ->(event) { event.request&.url.to_s.include?("/v2/gumhead/") }

  # A failed job's arguments ride on its event. A Help Center contact delivery
  # holds the message and up to 6 MB of base64 screenshots: stored in Sentry, or
  # past the SDK size limit, where the event is dropped silently. Matched on the
  # mailer name so contact jobs queued under MailDeliveryJob are covered too.
  redact_support_contact_job = lambda do |event|
    return unless event.tags.key?(:job_id)

    arguments = event.extra[:arguments]
    return unless arguments.is_a?(Array) && arguments.first == "SupportContactMailer"

    event.extra[:arguments] = arguments.map do |argument|
      next argument unless argument.is_a?(Hash) && argument[:args].is_a?(Array)

      argument.merge(args: argument[:args].map do |kwargs|
        next kwargs unless kwargs.is_a?(Hash)

        kwargs.merge(message: kwargs[:message].to_s.length, attachments: Array(kwargs[:attachments]).size)
      end)
    end
  end

  # Drop errors raised by ad-hoc `bin/rails runner` scripts piped in over STDIN
  # (their backtraces contain "stdin:<line>" frames). These are one-off console
  # commands typed by an operator — the person running the script sees the error
  # immediately in their terminal, so reporting it to Sentry only creates noise.
  # Sentry issue GUMROAD-80 grouped 175 of these unrelated typos under one title.
  # Errors from runner scripts that live in files (e.g. `bin/rails runner
  # lib/one_off/backfill.rb`) have real file paths in their backtraces and are
  # still reported, as is everything from the web/Sidekiq processes.
  config.before_send = lambda do |event, hint|
    exception = hint && hint[:exception]
    stdin_runner_error = event.tags[:source] == "runner" &&
      exception.respond_to?(:backtrace) &&
      exception.backtrace&.any? { |frame| frame.start_with?("stdin:") }

    return nil if stdin_runner_error || retired_gumhead_request.call(event)

    redact_support_contact_job.call(event)
    event
  end

  config.before_send_transaction = lambda do |event, _hint|
    retired_gumhead_request.call(event) ? nil : event
  end
end
