# frozen_string_literal: true

class CustomerMailer < ApplicationMailer
  include CurrencyHelper
  helper CurrencyHelper
  helper PreorderHelper
  helper ProductsHelper
  helper ApplicationHelper

  layout "layouts/email", except: :send_to_kindle

  def grouped_receipt(purchase_ids)
    @chargeables = Purchase.where(id: purchase_ids).includes(charge: [:order, :seller]).map { Charge::Chargeable.find_by_purchase_or_charge!(purchase: _1) }.uniq
    last_chargeable = @chargeables.last

    mail(
      to: last_chargeable.orderable.email,
      from: from_email_address_with_name(last_chargeable.seller.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      subject: "Receipts for Purchases",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers)
    )
  end

  # Note that the first argument is purchase_id, while the 2nd is charge_id
  # charge_id needs to be passed to the mailer only when the initial customer order is placed (via SendChargeReceiptJob)
  # For duplicate receipts (post-purchase), the purchase_id is passed, and the mailer will determine if it should use the
  # purchase, or the charge associated (via Charge::Chargeable.find_by_purchase_or_charge!)
  #
  def receipt(purchase_id = nil, charge_id = nil, for_email: true)
    @chargeable = Charge::Chargeable.find_by_purchase_or_charge!(
      purchase: Purchase.find_by(id: purchase_id),
      charge: Charge.find_by(id: charge_id)
    )
    @email_name = __method__

    @receipt_presenter = ReceiptPresenter.new(@chargeable, for_email:)

    is_receipt_for_gift_receiver = receipt_for_gift_receiver?(@chargeable)
    @footer_template = "layouts/mailers/receipt_footer" unless is_receipt_for_gift_receiver
    mail(
      to: @chargeable.orderable.email,
      from: from_email_address_with_name(@chargeable.seller.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      reply_to: @chargeable.support_email,
      subject: @receipt_presenter.mail_subject,
      template_name: is_receipt_for_gift_receiver ? "gift_receiver_receipt" : "receipt",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @chargeable.seller)
    )
  end

  def auto_invoice(purchase_id = nil, charge_id = nil)
    @chargeable = Charge::Chargeable.find_by_purchase_or_charge!(
      purchase: Purchase.find_by(id: purchase_id),
      charge: Charge.find_by(id: charge_id)
    )
    @email_name = __method__

    return unless AutoInvoiceEligibility.eligible?(@chargeable)

    billing_detail = @chargeable.purchaser.billing_detail
    pdf_bytes = InvoicePdfGenerator.new(@chargeable, billing_detail:).call
    attachments["invoice-#{@chargeable.external_id_numeric_for_invoice}.pdf"] = pdf_bytes

    mail(
      to: @chargeable.orderable.email,
      from: from_email_address_with_name(@chargeable.seller.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      reply_to: @chargeable.support_email,
      subject: "Your invoice from #{@chargeable.seller.name_or_username}",
      template_name: "auto_invoice",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @chargeable.seller)
    )
  end

  def preorder_receipt(preorder_id, link_id = nil, email = nil)
    @email_name = __method__
    if preorder_id.present?
      @preorder = Preorder.find_by(id: preorder_id)
      authorization_purchase = @preorder.authorization_purchase
      @product = @preorder.link
      email = authorization_purchase.email

      if @product.is_physical
        purchase = @preorder.authorization_purchase
        @shipping_info = {
          "full_name" => purchase.full_name,
          "street_address" => purchase.street_address,
          "city" => purchase.city,
          "zip_code" => purchase.zip_code,
          "state" => purchase.state,
          "country" => purchase.country
        }
      end
    else
      @product = Link.find(link_id)
    end
    mail(
      to: email,
      from: from_email_address_with_name(@product.user.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      reply_to: @product.support_email_or_default,
      subject: "You pre-ordered #{@product.name}!",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @product.user)
    )
  end

  def refund(email, link_id, purchase_id)
    @product = Link.find(link_id)
    @purchase = purchase_id ? Purchase.find(purchase_id) : nil
    # For purchases charged in the buyer's own currency, lead with the purchase total in
    # that currency — the number that matches their card statement — with the canonical
    # USD total alongside. This reads the purchase's charge-time presentment row (written
    # and committed when the purchase was made) instead of the just-created Refund row:
    # this email is enqueued inside the refund transaction, so a fast worker (or a lagging
    # read replica) could otherwise look the refund up before it is visible and silently
    # fall back to the legacy USD-only rendering. Using the purchase total also keeps the
    # copy right when earlier partial/tax-only refunds preceded this final refund — the
    # email describes the original purchase, not the last refund's remainder.
    if @purchase&.buyer_presentment?
      @formatted_presentment_total = @purchase.formatted_buyer_presentment_total
      # The "(… USD)" figure shown alongside must actually be in USD.
      # formatted_total_transaction_amount is in the product's display currency, which is
      # not necessarily USD, so format the USD cents explicitly here instead.
      @formatted_usd_total = formatted_price("usd", @purchase.total_transaction_cents)
    end
    mail(
      to: email,
      from: from_email_address_with_name(@product.user.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      reply_to: @product.user.support_or_form_email,
      subject: "You have been refunded.",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @product.user)
    )
  end

  # presentment_refund_amount_cents / presentment_refund_currency are the buyer-currency
  # amount of this specific refund, passed as plain values rather than a Refund id: the
  # job is enqueued inside the refund's database transaction, so a fast worker (or a
  # lagging read replica) could look the Refund row up before it is visible and silently
  # render the legacy USD-only email. Plain values survive that race. Both are nil for
  # non-presentment purchases and for jobs queued before these parameters existed.
  def partial_refund(email, link_id, purchase_id, refund_amount_cents_usd, refund_type, presentment_refund_amount_cents = nil, presentment_refund_currency = nil)
    @product = Link.find(link_id)
    @purchase = purchase_id ? Purchase.find(purchase_id) : nil
    amount_cents = usd_cents_to_currency(@product.price_currency_type, refund_amount_cents_usd, @purchase.rate_converted_to_usd)
    @formatted_refund_amount = formatted_price(@product.price_currency_type, amount_cents)
    if presentment_refund_currency.present? && presentment_refund_amount_cents.to_i > 0
      # Buyer-currency amount of this refund — the number that matches the buyer's card
      # statement — shown first, with the canonical USD amounts alongside.
      @formatted_presentment_refund_amount = formatted_price(presentment_refund_currency, presentment_refund_amount_cents)
      # Amounts shown next to a "USD" label must actually be formatted in USD.
      # @formatted_refund_amount above is in the product's price currency and
      # formatted_total_transaction_amount is in the display currency — neither is
      # guaranteed to be USD, so format the USD cents explicitly for those labels.
      @formatted_usd_refund_amount = formatted_price("usd", refund_amount_cents_usd)
      @formatted_usd_total = formatted_price("usd", @purchase.total_transaction_cents) if @purchase
    end
    @refund_type = refund_type
    mail(
      to: email,
      from: from_email_address_with_name(@product.user.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      reply_to: from_email_address_with_name(@product.user.name, @product.user.email),
      subject: "You have been #{@refund_type} refunded.",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @product.user)
    )
  end

  def send_to_kindle(kindle_email, product_file_id)
    product_file = ProductFile.find(product_file_id)

    temp_file = Tempfile.new
    product_file.s3_object.download_file(temp_file.path)
    temp_file.rewind
    attachments[product_file.s3_filename] = temp_file.read

    # tell amazon to convert the pdf to kindle-readable format
    mail(
      to: kindle_email,
      from: "noreply@#{CUSTOMERS_MAIL_DOMAIN}",
      subject: "convert",
      delivery_method_options: MailerInfo.default_delivery_method_options(domain: :customers)
    )
  end

  def paypal_purchase_failed(purchase_id)
    purchase = Purchase.find(purchase_id)
    @product = purchase.link
    mail(
      to: purchase.email,
      from: "noreply@#{CUSTOMERS_MAIL_DOMAIN}",
      subject: "Your purchase with PayPal failed.",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @product.user)
    )
  end

  def subscription_restarted(subscription_id, reason = nil)
    @reason = reason
    @subscription = Subscription.find(subscription_id)
    @edit_card_url = manage_subscription_url(@subscription.external_id, token: @subscription.refresh_token)
    @purchase = @subscription.original_purchase
    @footer_template = "layouts/mailers/subscription_restarted_footer"
    seller = @subscription.link.user
    mail(
      to: @subscription.email,
      from: from_email_address_with_name(seller.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      reply_to: seller.support_or_form_email,
      subject: @subscription.is_installment_plan? ? "Your installment plan has been restarted." : "Your subscription has been restarted.",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @purchase.seller)
    )
  end

  def subscription_magic_link(subscription_id, email)
    @subscription = Subscription.find(subscription_id)

    return unless EmailFormatValidator.valid?(email)

    mail(
      to: email,
      subject: "Magic Link"
    )
  end

  def abandoned_cart_preview(recipient_id, installment_id)
    user = User.find(recipient_id)
    installment = Installment.find(installment_id)

    @installments = [{
      subject: installment.subject,
      message: installment.message_with_inline_abandoned_cart_products(products: installment.workflow.abandoned_cart_products)
    }]

    mail(to: user.email, subject: installment.subject) do |format|
      format.html { render :abandoned_cart }
    end
  end

  # `workflow_ids_with_product_ids` is a hash of { workflow_id.to_s => product_ids }
  def abandoned_cart(cart_id, workflow_ids_with_product_ids, is_preview = false)
    cart = Cart.find(cart_id)
    return if !cart.abandoned?
    return if cart.email.blank? && cart.user&.email.blank?

    workflows = Workflow.where(id: workflow_ids_with_product_ids.keys).abandoned_cart_type.published.includes(:alive_installments)

    @installments = workflows.filter_map do |workflow|
      installment = workflow.alive_installments.sole
      products = workflow.abandoned_cart_products.select do |product|
        workflow_ids_with_product_ids[workflow.id.to_s].include?(ObfuscateIds.decrypt(product[:external_id]))
      end
      next if products.empty?

      {
        id: installment.id,
        subject: installment.subject,
        message: installment.message_with_inline_abandoned_cart_products(products:, checkout_url: checkout_url(host: UrlService.domain_with_protocol, cart_id: cart.secure_external_id(scope: "cart_login")))
      }
    end

    return if @installments.empty?

    @installments.each do |installment|
      SentAbandonedCartEmail.create!(cart_id: cart.id, installment_id: installment[:id])
    rescue ActiveRecord::RecordNotUnique
      # NoOp
    end unless is_preview

    subject = @installments.one? ? @installments.first[:subject] : "You left something in your cart"
    mail(
      to: cart.user&.email.presence || cart.email,
      subject:,
      from: "Gumroad <noreply@#{CUSTOMERS_MAIL_DOMAIN}>",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers)
    )
  end

  def review_response(review_response)
    review = review_response.product_review
    @review_presenter = ProductReviewPresenter.new(review).product_review_props
    @product = review.link
    seller = @product.user
    @seller_presenter = UserPresenter.new(user: seller).author_byline_props

    mail(
      to: review.purchase.email,
      subject: "#{@seller_presenter[:name]} responded to your review",
      from: from_email_address_with_name(seller.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      reply_to: seller.support_or_form_email,
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers)
    )
  end

  def upcoming_call_reminder(call_id)
    @purchase = Call.find(call_id).purchase
    @subject = "Your scheduled call with #{@purchase.seller.display_name} is tomorrow!"
    @item_info = ReceiptPresenter::ItemInfo.new(@purchase)
    mail(to: @purchase.email, subject: @subject)
  end

  def files_ready_for_download(purchase_id)
    @purchase = Purchase.find(purchase_id)
    @product = @purchase.link
    @url_redirect = @purchase.url_redirect

    mail(
      to: @purchase.email,
      from: from_email_address_with_name(@product.user.name, "noreply@#{CUSTOMERS_MAIL_DOMAIN}"),
      reply_to: @product.support_email_or_default,
      subject: "Your files are ready for download!",
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers, seller: @product.user)
    )
  end

  private
    def receipt_for_gift_receiver?(chargeable)
      chargeable.orderable.receipt_for_gift_receiver?
    rescue NotImplementedError
      false
    end
end
