# frozen_string_literal: true

class UserSignupMailerPreview < ActionMailer::Preview
  def confirmation_instructions
    UserSignupMailer.confirmation_instructions(User.last, {})
  end

  def reset_password_instructions
    User.last&.mark_compliant!(author_name: "Gullible Admin")
    UserSignupMailer.reset_password_instructions(User.last, {})
  end

  def reset_password_instructions_for_suspended_user
    User.last&.mark_compliant!
    User.last&.flag_for_fraud!(author_name: "Suspicious Admin")
    User.last&.suspend_for_fraud!(author_name: "Suspicious Admin")
    UserSignupMailer.reset_password_instructions(User.first, {})
  end

  def email_changed
    User.last&.update_attribute(:unconfirmed_email, "new+email@example.com")
    UserSignupMailer.email_changed(User.last, {})
  end
end
