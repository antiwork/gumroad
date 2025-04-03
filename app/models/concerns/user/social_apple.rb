# frozen_string_literal: true

module User::SocialApple
  extend ActiveSupport::Concern

  class_methods do
    def find_for_apple_auth(authorization_code:, app_type:)
      email = verified_apple_id_email(authorization_code:, app_type:)
      return if email.blank?

      User.find_by(email:)
    end

    private
      def verified_apple_id_email(authorization_code:, app_type:)
        client = AppleID::Client.new(apple_id_client_options[app_type])
        client.authorization_code = authorization_code
        token_response = client.access_token!
        id_token = token_response.id_token

        id_token.verify!(
          client:,
          access_token: token_response.access_token,
          verify_signature: false
        )

        id_token.email if id_token.email_verified?
      rescue AppleID::Client::Error => e
        Rails.logger.error "[Apple login error] #{e.full_message}"
        nil
      end

      def apple_id_client_options
        {
          Device::APP_TYPES[:consumer] => {
            identifier: GlobalConfig.get("IOS_CONSUMER_APP_APPLE_LOGIN_IDENTIFIER"),
            team_id: GlobalConfig.get("IOS_CONSUMER_APP_APPLE_LOGIN_TEAM_ID"),
            key_id: GlobalConfig.get("IOS_CONSUMER_APP_APPLE_LOGIN_KEY_ID"),
            private_key: OpenSSL::PKey::EC.new(GlobalConfig.get("IOS_CONSUMER_APP_APPLE_LOGIN_PRIVATE_KEY")),
          },
          Device::APP_TYPES[:creator] => {
            identifier: GlobalConfig.get("IOS_CREATOR_APP_APPLE_LOGIN_IDENTIFIER"),
            team_id: GlobalConfig.get("IOS_CREATOR_APP_APPLE_LOGIN_TEAM_ID"),
            key_id: GlobalConfig.get("IOS_CREATOR_APP_APPLE_LOGIN_KEY_ID"),
            private_key: OpenSSL::PKey::EC.new(GlobalConfig.get("IOS_CREATOR_APP_APPLE_LOGIN_PRIVATE_KEY")),
          }
        }
      end
  end
end
