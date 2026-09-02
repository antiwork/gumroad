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
    end
  end
end
