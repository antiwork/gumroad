# frozen_string_literal: true

class ServiceMailer < ApplicationMailer
  after_action :deliver_email

  layout "layouts/email"

  # service charge emails

  def service_charge_receipt(service_charge_id)
    @service_charge = ServiceCharge.find(service_charge_id)
    @user = @service_charge.user
    @subject = "Gumroad — Receipt"
  end

  # recurring service emails

  private
    def deliver_email
      return if @do_not_send

      email = @user.form_email
      return unless EmailFormatValidator.valid?(email)

      mailer_args = { to: email, subject: @subject }
      mailer_args[:from] = @from if @from.present?
      mail(mailer_args)
    end
end
