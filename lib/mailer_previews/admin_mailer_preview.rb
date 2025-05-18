# frozen_string_literal: true

class AdminMailerPreview < ActionMailer::Preview
  def chargeback_notify
    AdminMailer.chargeback_notify(Purchase.last.id)
  end
end
