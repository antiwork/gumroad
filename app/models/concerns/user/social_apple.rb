# frozen_string_literal: true

module User::SocialApple
  extend ActiveSupport::Concern

  class_methods do
    def find_or_create_for_apple_oauth(data)
      if data["uid"].blank?
        ErrorNotifier.notify("Apple OAuth data is missing a uid")
        return nil
      end

      auth = UserExternalAuthentication.find_by(provider: "apple", uid: data["uid"])
      user = auth&.user

      if user.nil?
        email = data.dig("info", "email")
        user = User.where(email:).first if EmailFormatValidator.valid?(email)

        if user.nil?
          user = User.new
          user.provider = :apple
          user.password = Devise.friendly_token[0, 20]
          apply_apple_data(user, data, new_user: true)

          if user.email.present?
            Purchase.where(email: user.email, purchaser_id: nil).each do |past_purchase|
              past_purchase.attach_to_user_and_card(user, nil, nil)
            end
          end
        else
          apply_apple_data(user, data)
        end
      else
        apply_apple_data(user, data)
      end

      user
    rescue ActiveRecord::RecordInvalid => e
      logger.error("Error finding or creating user via Apple OAuth: #{e.message}")
      ErrorNotifier.notify(e)
      nil
    end

    def find_for_apple_auth(authorization_code:, app_type:)
      email = verified_apple_id_email(authorization_code:, app_type:)
      return if email.blank?

      User.find_by(email:)
    end

    private
      def apply_apple_data(user, data, new_user: false)
        return if data.blank? || data.is_a?(String)

        email = data.dig("info", "email")

        if user.name.blank? && data.dig("info", "name").present?
          sanitized_name = data.dig("info", "name").gsub(User::INVALID_NAME_FOR_EMAIL_DELIVERY_REGEX, "")
          user.name = sanitized_name
        end

        if new_user && EmailFormatValidator.valid?(email)
          user.email = email
        end

        user.skip_confirmation_notification!
        user.save!
        user.confirm if user.has_unconfirmed_email?

        if data["uid"].present?
          user.user_external_authentications.find_or_create_by!(provider: "apple", uid: data["uid"])
        end

        user
      end

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
