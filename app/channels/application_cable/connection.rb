# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    rescue_from StandardError, with: :report_error

    delegate :session, to: :request

    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private
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
