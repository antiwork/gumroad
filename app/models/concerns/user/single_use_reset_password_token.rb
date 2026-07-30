# frozen_string_literal: true

class User
  # Devise clears the reset token in a `before_update`, so a concurrent request can still read it as
  # live mid-save and both saves succeed. Locking the row first makes the loser re-read after commit
  # and fall into Devise's invalid-token branch. The pwned-password HTTP check runs under this lock,
  # bounded by its 5s timeouts.
  #
  # Lock by primary key: a locking read through the token index takes next-key locks on the entry the
  # winner is about to clear, which MySQL resolves as a deadlock.
  module SingleUseResetPasswordToken
    extend ActiveSupport::Concern

    class_methods do
      def reset_password_by_token(attributes = {})
        digest = Devise.token_generator.digest(self, :reset_password_token, attributes[:reset_password_token])
        id = where(reset_password_token: digest).pick(:id) if digest.present?
        return super if id.nil?

        transaction do
          lock.find_by(id:)
          super
        end
      end
    end
  end
end
