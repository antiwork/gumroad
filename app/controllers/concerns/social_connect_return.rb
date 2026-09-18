# frozen_string_literal: true

module SocialConnectReturn
  extend ActiveSupport::Concern

  RETURN_LIFETIME = 15.minutes

  private
    # The destination is resolved here and kept in the session, never read back off the
    # callback's params: the token proves only that the return belongs to this seller's
    # own request, so a path taken from the wire would be an open redirect.
    def prepare_social_connect_return
      previous = session.delete(:social_connect_return)
      destination = social_connect_origin_destination
      return unless destination
      return unless logged_in_user == current_seller && policy([:settings, :social_connections]).show?

      if previous.is_a?(Hash) && previous["user_id"] == logged_in_user.id && previous["destination"] == destination &&
          previous["created_at"].is_a?(Integer) && (Time.current.to_i - previous["created_at"]).between?(0, RETURN_LIFETIME.to_i)
        session[:social_connect_return] = previous
        return previous["token"]
      end

      token = SecureRandom.hex(32)
      session[:social_connect_return] = { "token" => token, "user_id" => logged_in_user.id,
                                          "destination" => destination, "created_at" => Time.current.to_i }
      token
    end

    def social_connect_origin_destination
      case params[:social_connect_origin]
      when "onboarding" then dashboard_path
      when "marketing" then marketing_share_destination
      end
    end

    # Resolved against the seller's own published products, so the stored path cannot be
    # steered by the permalink in the query string.
    def marketing_share_destination
      permalink = params[:social_connect_product].to_s
      return if permalink.blank?

      product = logged_in_user.links.visible.find_by(unique_permalink: permalink)
      return unless product&.published?

      "#{edit_link_path(product.unique_permalink)}/share"
    end

    # Returns the stored destination, or nil when this callback is not a verified return.
    def consume_social_connect_return
      context = session.delete(:social_connect_return)
      token = request.env.dig("omniauth.params", "social_connect_return")
      return unless context.is_a?(Hash) && token.is_a?(String)
      return unless logged_in_user && logged_in_user == current_seller && context["user_id"] == logged_in_user.id
      return unless policy([:settings, :social_connections]).show?
      return unless context["created_at"].is_a?(Integer) && (Time.current.to_i - context["created_at"]).between?(0, RETURN_LIFETIME.to_i)
      return unless ActiveSupport::SecurityUtils.secure_compare(context["token"].to_s, token)

      context["destination"].presence
    end
end
