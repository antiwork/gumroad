# frozen_string_literal: true

class ServiceMailerPreview < ActionMailer::Preview
  def service_charge_receipt
    ServiceMailer.service_charge_receipt(ServiceCharge.last&.id)
  end
end
