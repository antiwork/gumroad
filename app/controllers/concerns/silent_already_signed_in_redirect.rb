# frozen_string_literal: true

module SilentAlreadySignedInRedirect
  extend ActiveSupport::Concern

  private
    def require_no_authentication
      assert_is_devise_resource!
      return unless is_navigational_format?
      no_input = devise_mapping.no_input_strategies

      authenticated = if no_input.present?
        args = no_input.dup.push scope: resource_name
        warden.authenticate?(*args)
      else
        warden.authenticated?(resource_name)
      end

      if authenticated && resource = warden.user(resource_name)
        redirect_to after_sign_in_path_for(resource)
      end
    end
end
