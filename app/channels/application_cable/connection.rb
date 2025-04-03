# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    rescue_from StandardError, with: :report_error

    delegate :session, to: :request

    identified_by :current_user

    def connect
      self.current_user = impersonated_user
    end

    private
      def impersonated_user
        user = find_verified_user
        return user unless user&.is_team_member?

        impersonated_user_id = $redis.get(RedisKey.impersonated_user(user.id))
        return user unless impersonated_user_id.present?

        impersonated_user = User.alive.find_by(id: impersonated_user_id)
        return user unless impersonated_user&.account_active?

        impersonated_user
      end

      def find_verified_user
        user_key = session["warden.user.user.key"]
        user_id = user_key.is_a?(Array) ? user_key.first&.first : nil

        if user_id
          User.find_by(id: user_id) || reject_unauthorized_connection
        else
          reject_unauthorized_connection
        end
      end

      def report_error(e)
        Rails.logger.error("Error in ActionCable connection: #{e.message}")
        reject_unauthorized_connection
      end
  end
end
