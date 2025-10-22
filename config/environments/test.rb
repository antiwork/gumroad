# frozen_string_literal: true

require "active_support/core_ext/integer/time"

# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = true

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with Cache-Control for performance.
  config.public_file_server.enabled = true
  config.public_file_server.headers = {
    "Cache-Control" => "public, max-age=#{1.hour.to_i}"
  }

  config.cache_store = :memory_store

  # Show full error reports and disable caching.
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = true

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Enable request forgery protection in test environment to match production ENV, disabled by default.
  config.action_controller.allow_forgery_protection = true

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "#{PROTOCOL}://#{ASSET_DOMAIN}"

  config.active_storage.service = :test

  config.action_mailer.perform_caching = true

  # config.action_mailer.delivery_method is configured in config/initializers/mailer.rb

  config.active_record.raise_on_assign_to_attr_readonly = true

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raises error for missing translations.
  config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  config.logger = Logger.new(nil) if ENV["RAILS_DISABLE_TEST_LOG"] == "true"
  config.log_level = (ENV["RAILS_LOG_LEVEL"] || "debug").to_sym

  config.active_job.queue_adapter = :test

  config.action_controller.raise_on_missing_callback_actions = true

  # Suppress mongoid queries in test
  config.mongoid.logger.level = Logger::INFO
end
