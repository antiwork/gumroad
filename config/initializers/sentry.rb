Sentry.init do |config|
  config.dsn = GlobalConfig.get("SENTRY_DSN")
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.send_default_pii = true
  config.traces_sample_rate = 0.01
end
