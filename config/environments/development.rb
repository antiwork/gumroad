# frozen_string_literal: true

require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing
  config.server_timing = true

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true

    config.cache_store = :mem_cache_store, *ENV.fetch("MEMCACHE_SERVERS").split(",")
    config.public_file_server.headers = {
      "Cache-Control" => "public, max-age=#{2.days.to_i}"
    }
  else
    config.action_controller.perform_caching = false

    config.cache_store = :null_store
  end

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  config.asset_host = "#{PROTOCOL}://#{ASSET_DOMAIN}"

  # Where to store uploaded files (see config/storage.yml for options)
  config.active_storage.service = :amazon

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  config.action_mailer.perform_caching = false
  config.action_mailer.preview_paths << "#{Rails.root}/lib/mailer_previews"

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  config.action_mailer.asset_host = "#{PROTOCOL}://#{DOMAIN}"

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = ENV["DISABLE_VERBOSE_QUERY_LOGS"] != "1"

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true

  config.action_controller.raise_on_missing_callback_actions = true

  # Bullet configuration for N+1 query detection
  config.after_initialize do
    Bullet.enable = true
    Bullet.alert = false
    Bullet.bullet_logger = true
    Bullet.rails_logger = true
    Bullet.add_footer = true
  end
end
