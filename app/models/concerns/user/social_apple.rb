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
  end
end
