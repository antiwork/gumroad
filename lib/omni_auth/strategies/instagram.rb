# frozen_string_literal: true

require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class Instagram < OAuth2
      class WrappedAccessToken < ::OAuth2::AccessToken
        def self.from_hash(client, response)
          token_data = response.fetch("data", []).first || response
          super(client, token_data)
        end
      end

      option :name, "instagram"
      option :scope, "instagram_business_basic"
      option :authorize_params, { enable_fb_login: "false", force_reauth: "true" }
      option :client_options,
             site: "https://api.instagram.com",
             authorize_url: "https://www.instagram.com/oauth/authorize",
             token_url: "https://api.instagram.com/oauth/access_token",
             auth_scheme: :request_body,
             access_token_class: WrappedAccessToken

      uid { access_token.params["user_id"] || access_token.params[:user_id] }
      info { {} }
      extra { { "raw_info" => access_token.params } }

      def request_phase
        return redirect(flag_off_redirect) unless instagram_connect_enabled?

        super
      end

      def callback_phase
        return redirect(flag_off_redirect) unless instagram_connect_enabled?

        super
      end

      private
        def instagram_connect_enabled?
          Feature.active?(:instagram_connect, instagram_connect_actor)
        end

        def instagram_connect_actor
          user = env["warden"]&.user
          return user unless user&.is_team_member?

          impersonated_user_id = $redis.get(RedisKey.impersonated_user(user.id))
          return user if impersonated_user_id.blank?

          User.alive.find_by(id: impersonated_user_id) || user
        end

        def flag_off_redirect
          instagram_connect_actor.present? ? "/profile" : "/login"
        end
    end
  end
end
