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

    mail subject: "#{SUBJECT_PREFIX}Low balance for creator - #{@user.name} (#{@user.balance_formatted})",
         to: RISK_EMAIL
  end

  # Sent when AutoFlagInvertedSalesToViews unpublishes a product because its free sales ran
  # far ahead of its page views. Nobody has to act for the sends to stop — the product is
  # already down by the time this arrives. The detector deliberately leaves the account
  # alone, because anybody can check out a public free product, so this email is how a human
  # gets to decide whether the seller was behind it or the target of it.
  def inverted_sales_to_views_notify(product_id, sales_count, views_count)
    @product = Link.find(product_id)
    @user = @product.user
    @sales_count = sales_count
    @views_count = views_count

    mail subject: "#{SUBJECT_PREFIX}Auto-unpublished for inverted sales-to-views - #{@product.name} (#{ActiveSupport::NumberHelper.number_to_delimited(sales_count)} sales / #{ActiveSupport::NumberHelper.number_to_delimited(views_count)} views)",
         to: RISK_EMAIL
  end
end
