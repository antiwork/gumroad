# frozen_string_literal: true

class ReceiptPresenter
  attr_reader :for_email

  # chargeable is either a Purchase or a Charge
  def initialize(chargeable, for_email:)
    @for_email = for_email
    @chargeable = chargeable
  end

  def charge_info
    @_charge_info ||= ReceiptPresenter::ChargeInfo.new(
      chargeable,
      for_email:,
      order_items_count: chargeable.unbundled_purchases.count
    )
  end

  def payment_info
    @_payment_info ||= ReceiptPresenter::PaymentInfo.new(chargeable)
  end

  def shipping_info
    @_shipping_info ||= ReceiptPresenter::ShippingInfo.new(chargeable)
  end

  def items_infos
    chargeable.unbundled_purchases.map do |purchase_item|
      ReceiptPresenter::ItemInfo.new(purchase_item)
    end
  end

  def recommended_products_info
    @_recommended_products_info ||= ReceiptPresenter::RecommendedProductsInfo.new(chargeable)
  end

  def mail_subject
    @_mail_subject ||= ReceiptPresenter::MailSubject.build(chargeable)
  end

  def footer_info
    @_footer_info ||= ReceiptPresenter::FooterInfo.new(chargeable)
  end

  def giftee_manage_subscription
    @_giftee_manage_subscription ||= ReceiptPresenter::GifteeManageSubscription.new(chargeable)
  end

  private
    attr_reader :chargeable
end
