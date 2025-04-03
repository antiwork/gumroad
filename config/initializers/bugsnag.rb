# frozen_string_literal: true

require Rails.root.join("lib", "extras", "bugsnag_handle_sidekiq_retries_callback")

unless Rails.env.test?
  Rails.application.config.after_initialize do
    Bugsnag.configure do |config|
      config.api_key = GlobalConfig.get("BUGSNAG_API_KEY")
      config.notify_release_stages = %w[production staging]
      custom_ignored_classes = Set.new([
                                         ActionController::RoutingError,
                                         ActionController::InvalidAuthenticityToken,
                                         AbstractController::ActionNotFound,
                                         Mongoid::Errors::DocumentNotFound,
                                         ActionController::UnknownFormat,
                                         ActionController::UnknownHttpMethod,
                                         ActionController::BadRequest,
                                         Mime::Type::InvalidMimeType,
                                         ActionController::ParameterMissing,
                                       ])
      config.ignore_classes.merge(custom_ignored_classes)
      config.add_on_error BugsnagHandleSidekiqRetriesCallback
    end
  end
end
