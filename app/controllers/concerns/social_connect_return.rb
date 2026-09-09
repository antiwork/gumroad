# frozen_string_literal: true

module SocialConnectReturn
  extend ActiveSupport::Concern

  RETURN_LIFETIME = 15.minutes

  private
    def prepare_social_connect_return
      previous = session.delete(:social_connect_return)
      return unless params[:social_connect_origin] == "onboarding"
      return unless logged_in_user == current_seller && policy([:settings, :profile]).manage_social_connections?

      if previous.is_a?(Hash) && previous["user_id"] == logged_in_user.id &&
          previous["created_at"].is_a?(Integer) && (Time.current.to_i - previous["created_at"]).between?(0, RETURN_LIFETIME.to_i)
        session[:social_connect_return] = previous
        return previous["token"]
      end

      token = SecureRandom.hex(32)
      session[:social_connect_return] = { "token" => token, "user_id" => logged_in_user.id, "created_at" => Time.current.to_i }
      token
    end

    def consume_social_connect_return
      context = session.delete(:social_connect_return)
      token = request.env.dig("omniauth.params", "social_connect_return")
      return false unless context.is_a?(Hash) && token.is_a?(String)
      return false unless logged_in_user && logged_in_user == current_seller && context["user_id"] == logged_in_user.id
      return false unless policy([:settings, :profile]).manage_social_connections?
      return false unless context["created_at"].is_a?(Integer) && (Time.current.to_i - context["created_at"]).between?(0, RETURN_LIFETIME.to_i)

      ActiveSupport::SecurityUtils.secure_compare(context["token"].to_s, token)
    end
end
