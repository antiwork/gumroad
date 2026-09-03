# frozen_string_literal: true

require "omniauth-google-oauth2"

module OmniAuth
  module Strategies
    # Dedicated Google OAuth client for YouTube connect. Named separately so
    # login Google OAuth stays email+profile and does not start asking every
    # signer-in for youtube.readonly.
    class Youtube < GoogleOauth2
      option :name, "youtube"
      option :scope, "email,profile,https://www.googleapis.com/auth/youtube.readonly"
      option :prompt, "select_account"
      option :access_type, "online"

      def request_phase
        return redirect(flag_off_redirect) unless youtube_connect_enabled?

        super
      end

      def callback_phase
        return redirect(flag_off_redirect) unless youtube_connect_enabled?

        super
      end

      private
        def youtube_connect_enabled?
          Feature.active?(:youtube_connect, youtube_connect_actor)
        end

        # Match LoggedInUser: impersonated seller when a team member is impersonating,
        # otherwise the signed-in user. The settings button keys the same Flipper actor.
        def youtube_connect_actor
          user = env["warden"]&.user
          return user unless user&.is_team_member?

          impersonated_user_id = $redis.get(RedisKey.impersonated_user(user.id))
          return user if impersonated_user_id.blank?

          User.alive.find_by(id: impersonated_user_id) || user
        end

        def flag_off_redirect
          youtube_connect_actor.present? ? "/profile" : "/login"
        end
    end
  end
end
