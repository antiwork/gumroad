# frozen_string_literal: true

require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class Tiktok < OAuth2
      option :name, "tiktok"
      option :scope, "user.info.basic,user.info.profile,user.info.stats"
      option :client_options,
             site: "https://open.tiktokapis.com",
             authorize_url: "https://www.tiktok.com/v2/auth/authorize/",
             token_url: "https://open.tiktokapis.com/v2/oauth/token/",
             auth_scheme: :request_body

      uid { access_token.params["open_id"] || access_token.params[:open_id] }
      info { {} }
      extra { { "raw_info" => access_token.params } }

      def callback_url
        full_host + callback_path
      end

      def authorize_params
        super.tap do |params|
          params[:client_key] = options.client_id
          params.delete(:client_id)
        end
      end

      def token_params
        super.tap do |params|
          params[:client_key] = options.client_id
          params[:client_secret] = options.client_secret
        end
      end

      def request_phase
        return redirect(flag_off_redirect) unless tiktok_connect_enabled?

        params = authorize_params.merge(redirect_uri: callback_url)
        params[:client_key] = client.id
        params.delete(:client_id)
        params.delete("client_id")
        authorize_url = options.client_options[:authorize_url]
        redirect "#{authorize_url}#{authorize_url.include?("?") ? "&" : "?"}#{Rack::Utils.build_query(params)}"
      end

      def callback_phase
        return redirect(flag_off_redirect) unless tiktok_connect_enabled?

        super
      end

      private
        def tiktok_connect_enabled?
          Feature.active?(:tiktok_connect, tiktok_connect_actor)
        end

        def tiktok_connect_actor
          user = env["warden"]&.user
          return user unless user&.is_team_member?

          impersonated_user_id = $redis.get(RedisKey.impersonated_user(user.id))
          return user if impersonated_user_id.blank?

          User.alive.find_by(id: impersonated_user_id) || user
        end

        def flag_off_redirect
          tiktok_connect_actor.present? ? "/profile" : "/login"
        end
    end
  end
end
