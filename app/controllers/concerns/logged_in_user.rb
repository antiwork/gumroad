# frozen_string_literal: true

module LoggedInUser
  extend ActiveSupport::Concern

  included do
    helper_method :logged_in_user
  end

  # Usage of current_user is restricted to ensure current_user is not used accidentaly instead of current_seller
  def logged_in_user
    impersonated_user || current_user
  end
end
