# frozen_string_literal: true

# Delivers Help Center contact form submissions to the support inbox
# (support@gumroad.com), which is ingested by Helper — so form submissions land
# in the same support pipeline as direct emails. `reply_to` is set to the
# submitter so agent replies thread back to them.
class SupportContactMailer < ApplicationMailer
  layout "layouts/email"

  def contact_form(email:, category:, message:, user_id: nil, referrer_path: nil)
    @email = email
    @category = category
    @message = message
    @user = User.find_by(id: user_id) if user_id
    @referrer_path = referrer_path

    mail to: SUPPORT_EMAIL,
         reply_to: email,
         subject: "Help Center contact form: #{category}"
  end
end
