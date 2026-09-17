# frozen_string_literal: true

# Delivers Help Center contact form submissions to the support inbox
# (support@gumroad.com), which is ingested by Helper — so form submissions land
# in the same support pipeline as direct emails. `reply_to` is set to the
# submitter so agent replies thread back to them.
class SupportContactMailer < ApplicationMailer
  layout "layouts/email"

  # The sender is always noreply@gumroad.com, so Gmail threads on subject alone;
  # a fixed subject merged unrelated submissions into one conversation. The
  # submitter plus a per-submission token keep each message separate.
  def contact_form(email:, category:, message:, user_id: nil, referrer_path: nil)
    @email = email
    @category = category
    @message = message
    @user = User.find_by(id: user_id) if user_id
    @referrer_path = referrer_path

    mail to: SUPPORT_EMAIL,
         reply_to: email,
         subject: contact_form_subject(email:, category:)
  end

  private
    def contact_form_subject(email:, category:)
      submitter = email.to_s.tr("\r\n", " ").strip
      "Help Center contact form: #{category} - #{submitter} [#{SecureRandom.hex(4)}]"
    end
end
