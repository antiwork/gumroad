# frozen_string_literal: true

class OneOffMailerPreview < ActionMailer::Preview
  def email
    subject = "Try our premium features, for free!"
    body = <<~BODY
    You can now try out our premium features with a 14-day free trial. They make Gumroad a lot more powerful. It also comes with cheaper per-charge pricing.
    You can cancel your account at any time and won't be charged anything.

    <a class="button accent" href="https://gumroad.com/settings/upgrade">Learn more</a>

    Best,
    Sahil and the Gumroad Team.
    BODY
    OneOffMailer.email(user_id: User.last&.id, subject:, body:)
  end

  def email_using_installment
    OneOffMailer.email_using_installment(user_id: User.last&.id, installment_external_id: Installment.last&.external_id)
  end
end
