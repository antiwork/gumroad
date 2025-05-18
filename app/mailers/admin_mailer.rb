# frozen_string_literal: true

class AdminMailer < ApplicationMailer
  SUBJECT_PREFIX = ("[#{Rails.env}] " unless Rails.env.production?)

  default from: ADMIN_EMAIL
  default to: DEVELOPERS_EMAIL

  layout "layouts/email"

  def chargeback_notify(dispute_id)
    dispute = Dispute.find(dispute_id)
    @disputable = dispute.disputable
    @user = @disputable.seller

    subject = "#{SUBJECT_PREFIX}Chargeback for #{@disputable.formatted_disputed_amount} on #{@disputable.purchase_for_dispute_evidence.link.name}"
    subject += " and #{@disputable.disputed_purchases.count - 1} other products" if @disputable.multiple_purchases?

    mail subject:,
         to: RISK_EMAIL
  end

  def low_balance_notify(user_id, last_refunded_purchase_id)
    @user = User.find(user_id)
    @purchase = Purchase.find(last_refunded_purchase_id)
    @product = @purchase.link

    mail subject: "#{SUBJECT_PREFIX}Low balance for creator - #{@user.name} (#{@user.balance_formatted(via: :elasticsearch)})",
         to: RISK_EMAIL
  end
end
