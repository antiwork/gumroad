# frozen_string_literal: true

module SilentAlreadySignedInRedirect
  extend ActiveSupport::Concern

  private
    def require_no_authentication
      return unless is_navigational_format?
      return unless user_signed_in?

      redirect_to after_sign_in_path_for(current_user)
    end
end
