# frozen_string_literal: true

class ReceiptPresenter
  include BuyerPresentmentDisplay

  # $color-surface in the email stylesheet.
  EMAIL_CARD_COLOR = "#ffffff"
  # $color-subtle: the panel a receipt's item, and so its download button, sits on.
  EMAIL_PANEL_COLOR = "#f8f8f5"
  # A value longer than this (a gift message) reads as a sentence, so it goes under its label,
  # left-aligned.
  LONG_ATTRIBUTE_VALUE_LENGTH = 40

  attr_reader :for_email

  # chargeable is either a Purchase or a Charge
  def initialize(chargeable, for_email:, recommendations: true, screen_seller_text: true)
    @screen_seller_text = screen_seller_text
    @for_email = for_email
    @chargeable = chargeable
    @recommendations = recommendations
  end

  def charge_info
    @_charge_info ||= ReceiptPresenter::ChargeInfo.new(
      chargeable,
      for_email:,
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
      ReceiptPresenter::ItemInfo.new(purchase_item, presentment_currency:, screen_seller_text: @screen_seller_text)
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

  # The seller's accent for the receipt's button and, when they have an avatar, their avatar and
  # name for the email header; nil for a receipt that stays Gumroad's. Without an avatar the
  # header would show the default one, so it keeps Gumroad's wordmark.
  def seller_branding
    seller = chargeable.seller
    return unless Feature.active?(:seller_branded_receipt, seller)

    branding = { button_style: seller.seller_profile.email_primary_button_style(surface: EMAIL_PANEL_COLOR) }
    branding[:email_brand] = { name: seller.name_or_username, url: seller.profile_url, logo_url: seller.avatar_url } if seller.avatar.attached?
    branding
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
