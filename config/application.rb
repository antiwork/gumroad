# frozen_string_literal: true

require_relative "boot"

require "rails/all"
require "action_cable/engine"

require "socket"
require_relative "../lib/catch_bad_request_errors"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

if Rails.env.development? || Rails.env.test?
  Dotenv::Railtie.load
end

require_relative "domain"
require_relative "redis"
require_relative "../lib/utilities/global_config"

module Gumroad
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.0
    config.active_support.cache_format_version = 7.1
    config.active_storage.variant_processor = :mini_magick

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # config.autoload_lib(ignore: %w(assets currency json_schema tasks))

    config.to_prepare do
      Devise::Mailer.helper MailerHelper
      Devise::Mailer.layout "email"
      DeviseController.respond_to :html, :json
      Doorkeeper::ApplicationsController.layout "application"
      Doorkeeper::AuthorizationsController.layout "application"
    end

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    config.eager_load_paths += %w[./lib/utilities]
    config.eager_load_paths += %w[./lib/validators]
    config.eager_load_paths += %w[./lib/errors]
    config.eager_load_paths += Dir[Rails.root.join("app", "business", "**/")]

    config.middleware.insert_before(ActionDispatch::Cookies, Rack::SSL, exclude: ->(env) { env["HTTP_HOST"] != DOMAIN || Rails.env.test? || Rails.env.development? })

    config.action_view.sanitized_allowed_tags = ["div", "p", "a", "u", "strong", "b", "em", "i", "br"]
    config.action_view.sanitized_allowed_attributes = ["href", "class", "target"]

    # Configure the default encoding used in templates for Ruby 1.9.
    config.encoding = "utf-8"

    if Rails.env.development? || Rails.env.test?
      logger = ActiveSupport::Logger.new("log/#{Rails.env}.log", "weekly")
      logger.formatter = config.log_formatter
    else
      logger = Logger.new(STDOUT)
      config.lograge.enabled = true
    end

    config.logger = ActiveSupport::TaggedLogging.new(logger)

    config.middleware.insert 0, Rack::UTF8Sanitizer

    initializer "catch_bad_request_errors.middleware" do
      config.middleware.insert_after Rack::Attack, ::CatchBadRequestErrors
    end

    config.generators do |g|
      g.helper_specs false
      g.stylesheets false
      g.test_framework :rspec, fixture: true, views: false
      g.fixture_replacement :factory_bot, dir: "spec/support/factories"
      g.orm :active_record
    end

    config.active_job.queue_adapter = :sidekiq

    config.hosts = nil

    config.mongoid.logger.level = Logger::INFO

    config.active_storage.queues.purge = :low

    config.flipper.strict = false
    config.flipper.test_help = false
  end
end
