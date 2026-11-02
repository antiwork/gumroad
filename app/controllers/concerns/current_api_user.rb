# frozen_string_literal: true

# Equivalent of current_user for API
#
module CurrentApiUser
  extend ActiveSupport::Concern

  included do
    helper_method :current_api_user
  end

  def current_api_user
    # Client-credentials tokens act as an application, not a user.
    return unless defined?(doorkeeper_token) && doorkeeper_token&.resource_owner_id.present?

    @_current_api_user ||= User.find(doorkeeper_token.resource_owner_id)
  rescue ActionDispatch::Http::Parameters::ParseError
    @_current_api_user = nil
  end
end
