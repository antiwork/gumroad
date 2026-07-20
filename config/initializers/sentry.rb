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
    "Mongoid::Errors::DocumentNotFound",
    "ActionController::UnknownFormat",
    "ActionController::UnknownHttpMethod",
    "ActionController::BadRequest",
    "Mime::Type::InvalidMimeType",
    "ActionController::ParameterMissing",
  ]

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

    stdin_runner_error ? nil : event
  end
end
