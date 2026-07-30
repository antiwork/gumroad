# frozen_string_literal: true

class User
  # Makes consuming a password-reset token single-use under concurrency.
  #
  # Devise clears the token in a `before_update` callback, so the token is still live in the
  # database while a request validates and saves the new password. Two requests carrying the
  # same token can therefore both read it as valid and both save, leaving the final password
  # decided by whichever write lands last. Locking the row before Devise reads it makes the
  # second request wait, then re-read a row whose token is already gone, which lands it in
  # Devise's existing invalid-token branch.
  #
  # The lock is taken by primary key, not by `reset_password_token`. Locking through the
  # token's index makes the two requests hold conflicting next-key locks on the very index
  # entry the winner is about to clear, which MySQL resolves as a deadlock — a 500 for the
  # request that loses, instead of the invalid-token page it should get.
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
