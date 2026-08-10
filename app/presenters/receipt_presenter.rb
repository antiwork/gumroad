# frozen_string_literal: true

class ReceiptPresenter
  include BuyerPresentmentDisplay

  attr_reader :for_email

  # chargeable is either a Purchase or a Charge
  def initialize(chargeable, for_email:, recommendations: true)
    @for_email = for_email
    @chargeable = chargeable
    @recommendations = recommendations
  end

  def charge_info
    @_charge_info ||= ReceiptPresenter::ChargeInfo.new(
      chargeable,
      for_email:,
      order_items_count: chargeable.unbundled_purchases.count,
      presentment_currency:
    )
  end

  def payment_info
    @_payment_info ||= ReceiptPresenter::PaymentInfo.new(chargeable, presentment_currency:)
  end

  def shipping_info
    @_shipping_info ||= ReceiptPresenter::ShippingInfo.new(chargeable)
  end

  def items_infos
    chargeable.unbundled_purchases.map do |purchase_item|
      ReceiptPresenter::ItemInfo.new(purchase_item, presentment_currency:)
    end
  end

  def recommended_products_info
    @_recommended_products_info ||= ReceiptPresenter::RecommendedProductsInfo.new(chargeable, recommendations: @recommendations)
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

  # The single currency this document is stated in, or nil when it falls back to canonical
  # USD. Decided here, once, and handed to every section the receipt renders — including
  # each item line — because making the decision reads every purchase's refunds, so a
  # section deciding for itself would repeat that read once per line on the receipt.
  #
  # Memoized on defined? rather than ||= because nil is a real answer we must not recompute.
  def presentment_currency
    return @_presentment_currency if defined?(@_presentment_currency)

    @_presentment_currency = buyer_presentment_display_currency(chargeable.successful_purchases)
  end

  private
    attr_reader :chargeable
end
