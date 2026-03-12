# frozen_string_literal: true

module PunditAuthorization
  extend ActiveSupport::Concern
  include Pundit::Authorization

  included do
    rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

    helper_method :pundit_user
  end

  def pundit_user
    @_pundit_user ||= SellerContext.new(user: logged_in_user, seller: current_seller)
  end

  private
    def user_not_authorized(exception)
      if exception.policy.class == LinkPolicy && exception.query == "edit?"
        product_edit_user_not_authorized(exception.record)
      elsif exception.policy.class == Settings::Main::UserPolicy && exception.query == "show?"
        settings_main_user_not_authorized
      else
        default_user_not_authorized(exception)
      end
    end

    def product_edit_user_not_authorized(product)
      # Sometimes sellers share the edit product link with their audience by accident.
      # For a better user experience redirect to the actual product page for a better user experience, rather than
      # displaying the _Not Authorized_ message
      redirect_to short_link_path(product)
    end

    def settings_main_user_not_authorized
      # This allows keeping the Nav link to settings_main_path, and redirect to the profile page for those roles
      # that don't have access to it
      # All roles have at least read-only access to the profile page
      redirect_to settings_profile_path
    end

    # It could happen for reasons like:
    # - a UI element allows the user to access a resource that is not authorized
    # - the user manually accessed a page for which is not authorized (i.e. /settings/password by non-owner)
    # These are not usual use cases of the app, so logging it to be notified there are bugs that need fixing.
    # Also, do not log and do not set a flash alert when the user is switching accounts, as this is a normal use case.
    #
    def default_user_not_authorized(exception)
      Rails.logger.warn(debug_message(exception)) unless params["account_switched"]

      message = build_error_message
      if request.format.json? || request.format.js?
        render json: { success: false, error: message }, status: :unauthorized
      else
        flash[:alert] = message unless params["account_switched"]
        redirect_to dashboard_url
      end
    end

    def build_error_message
      # Some policies (like CommentContextPolicy#index?) do not require the user to be authenticated
      return "You are not allowed to perform this action." if
        !user_signed_in? ||
        logged_in_user.role_owner_for?(current_seller)

      team_membership = logged_in_user.find_user_membership_for_seller!(current_seller)

      "Your current role as #{team_membership.role.humanize} cannot perform this action."
    rescue ActiveRecord::RecordNotFound
      # This should not happen, but if it does, we want to be notified so we can fix it
      Bugsnag.notify("Team: Could not find membership for user #{logged_in_user.id} and seller #{current_seller.id}")

      "You are not allowed to perform this action."
    end

    def debug_message(exception)
      if user_signed_in?
        "Pundit::NotAuthorizedError for #{exception.policy.class} " \
        "by User ID #{pundit_user.user.id} for Seller ID #{pundit_user.seller.id}: #{exception.message}"
      else
        "Pundit::NotAuthorizedError for #{exception.policy.class} by unauthenticated user: #{exception.message}"
      end
    end
end
