# frozen_string_literal: true

class ReceiptPresenter::ChargeInfo
  include ActionView::Helpers::UrlHelper
  include CurrencyHelper
  include MailerHelper
  include ERB::Util

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
    formatted_dollar_amount(chargeable.charged_amount_cents)
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
end
