# frozen_string_literal: true

class ReceiptPresenter::ChargeInfo
  include ActionView::Helpers::UrlHelper
  include CurrencyHelper
  include MailerHelper
  include ERB::Util
  include BuyerPresentmentDisplay

  def initialize(chargeable, for_email:, order_items_count:)
    @for_email = for_email
    @order_items_count = order_items_count
    @chargeable = chargeable
    @seller = chargeable.seller
  end

  def formatted_created_at
    chargeable.orderable.created_at.to_fs(:formatted_date_abbrev_month)
  end

  def formatted_total_transaction_amount
    if presentment_currency.present?
      MoneyFormatter.format(presentment_total_cents, presentment_currency.to_sym, no_cents_if_whole: true, symbol: true)
    else
      formatted_dollar_amount(chargeable.charged_amount_cents)
    end
  end

  def order_id
    chargeable.external_id_for_invoice
  end

  def product_questions_note
    return if chargeable.orderable.receipt_for_gift_sender?

    question = "Questions about your #{"product".pluralize(order_items_count)}?"

    action = \
      if for_email
        "Contact #{h(seller.display_name)} by replying to this email."
      else
        "Contact #{h(seller.display_name)} at #{mail_to(chargeable.support_email)}."
      end
    "#{question} #{action}".html_safe
  rescue NotImplementedError
    nil
  end

  private
    attr_reader :for_email, :order_items_count, :chargeable, :seller

    # Memoized because deciding this walks every purchase's refunds, and
    # formatted_total_transaction_amount asks for it twice (once to choose the currency,
    # once to format in it). nil is a meaningful answer here — it means the document
    # falls back to canonical USD — so the memo is guarded on defined? rather than ||=,
    # which would re-run the queries every time the answer is "fall back to USD".
    def presentment_currency
      return @_presentment_currency if defined?(@_presentment_currency)

      @_presentment_currency = buyer_presentment_display_currency(chargeable.successful_purchases)
    end

    def presentment_total_cents
      chargeable.successful_purchases.sum { _1.buyer_presentment_total_cents.to_i }
    end
end
