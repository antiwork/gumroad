# frozen_string_literal: true

class InviteMailer < ApplicationMailer
  layout "layouts/email"

  def receiver_signed_up(invite_id)
    @invite   = Invite.find(invite_id)
    @sender   = User.find(@invite.sender_id)
    @receiver = User.find(@invite.receiver_id)

    @subject = if @receiver.name.present?
      "#{@receiver.name} has joined Gumroad, thanks to you."
    else
      "A creator you invited has joined Gumroad."
    end
    deliver_email(to: @sender.form_email)
  end

  private
    def deliver_email(to:)
      return if to.blank?

      mail to:, subject: @subject
    end
end
