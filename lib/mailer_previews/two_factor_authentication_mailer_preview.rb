# frozen_string_literal: true

class TwoFactorAuthenticationMailerPreview < ActionMailer::Preview
  def authentication_token
    TwoFactorAuthenticationMailer.authentication_token(User.where.not(email: nil).last&.id)
  end
end
