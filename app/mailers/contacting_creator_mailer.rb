# frozen_string_literal: true

class ContactingCreatorMailer < ApplicationMailer
  include ActionView::Helpers::NumberHelper
  include ActionView::Helpers::TagHelper
  include ActionView::Helpers::UrlHelper
  include ActionView::Helpers::TextHelper
  include CurrencyHelper
  include CustomMailerRouteBuilder
  include SocialShareUrlHelper
  include NotifyOfSaleHeaders
  helper ProductsHelper
  helper CurrencyHelper
  helper PreorderHelper
  helper InstallmentsHelper

  default from: ApplicationMailer::SUPPORT_EMAIL_WITH_NAME

  after_action :deliver_email
  after_action :send_push_notification!, only: :notify

  layout "layouts/email"

  def notify(purchase_id, is_preorder = false, email = nil, link_id = nil, price_cents = nil, variants = nil,
             shipping_info = nil, custom_fields = nil, offer_code_id = nil)
    if purchase_id
      @purchase = Purchase.find(purchase_id)
      @is_preorder = is_preorder
      return do_not_send if @purchase.nil?
      @product = @purchase.link
      @variants = @purchase.variants_list
      @quantity = @purchase.quantity
      @variants_count = @purchase.variant_names&.count || 0
      @custom_fields = @purchase.custom_fields
      @offer_code = @purchase.offer_code
      @display_offer_code = @purchase.original_offer_code(include_deleted: true)
    else
      @product = Link.find(link_id)
      @variants = variants
      @variants_count = variants&.count || 0
      @custom_fields = custom_fields
      @offer_code = offer_code_id.present? ? OfferCode.find(offer_code_id) : nil
      @display_offer_code = @offer_code
    end

    if @product.is_tiered_membership? && @variants_and_quantity == "(Untitled)"
      @variants_and_quantity = nil
    end

    if price_cents.present?
      @price = Money.new(price_cents, @product.price_currency_type.to_sym).format(no_cents_if_whole: true, symbol: true)
    elsif @purchase&.commission.present?
      @price = format_just_price_in_cents(@purchase.displayed_price_cents + @purchase.commission.completion_display_price_cents, @purchase.displayed_price_currency_type)
    elsif @purchase.nil?
      @price = @product.price_formatted
    end

    if @product.require_shipping
      @shipping_info = shipping_info || {
        "full_name" => @purchase.full_name,
        "street_address" => @purchase.street_address,
        "city" => @purchase.city,
        "zip_code" => @purchase.zip_code,
        "state" => @purchase.state,
        "country" => @purchase.country
      }
    end

    if email.present?
      @purchaser_email = email
    elsif @purchase.email.present?
      @purchaser_email = @purchase.email
    elsif @purchase.purchaser.present? && @purchase.purchaser.email.present?
      @purchaser_email = @purchase.purchaser.email
    end

    @buyer_name = @purchase.try(:full_name)
    @seller = @product.user
    @unsub_link = user_unsubscribe_url(id: @seller.secure_external_id(scope: "email_unsubscribe"), email_type: :notify)
    @reply_to = @purchase.try(:email)

    set_notify_of_sale_headers(is_preorder:)

    @referrer_name = @purchase&.display_referrer

    do_not_send unless should_send_email?
  end

  def chargeback_notice(dispute_id)
    dispute = Dispute.find(dispute_id)
    @disputable = dispute.disputable
    @is_paypal = @disputable.charge_processor == PaypalChargeProcessor.charge_processor_id
    @seller = @disputable.seller

    dispute_evidence = dispute.dispute_evidence
    # Recomputed at delivery, not at enqueue: a notice queued with an hour left can be delivered with
    # none, and the seller may have answered or the row been resolved in between. Asking through the
    # same predicate the submission endpoint enforces keeps the ask from outliving the page it links to.
    #
    # hours_left is read FIRST and the gate is ANDed with it: accepting_evidence? reads its own clock,
    # so the two calls can straddle the window's end and quote "the next 0 hours" past the gate.
    hours_left = dispute_evidence&.hours_left_to_submit_evidence
    asking_for_evidence = dispute_evidence&.accepting_evidence? && hours_left&.positive?
    @dispute_evidence_content = \
      if asking_for_evidence
        safe_join(
          [
            tag.p(tag.b("Any additional information you can provide in the next #{pluralize(hours_left, "hour")} will help us win on your behalf.")),
            tag.p(
              link_to(
                "Submit additional information",
                purchase_dispute_evidence_url(@disputable.purchase_for_dispute_evidence.external_id),
                class: "button primary"
              )
            )
          ]
        )
      end

    @subject = \
      if @is_paypal.present?
        "A PayPal sale has been disputed"
      elsif asking_for_evidence
        "🚨 Urgent: Action required for resolving disputed sale"
      else
        "A sale has been disputed"
      end
  end

  def remind(user_id)
    @seller = User.find_by(id: user_id)
    return unless @seller

    @unsub_link = user_unsubscribe_url(id: @seller.secure_external_id(scope: "email_unsubscribe"), email_type: :product_update)
    @sales_count = @seller.sales.successful.count
    @subject = "Please add a payment account to Gumroad."
  end

  def video_preview_conversion_error(link_id)
    @product = Link.find(link_id)
    @seller = @product.user
    @subject = "We were unable to process your preview video."
  end

  def seller_update(user_id)
    @end_of_period = Date.today.beginning_of_week(:sunday).to_datetime
    @start_of_period = @end_of_period - 7.days
    @seller = User.find(user_id)
    @unsub_link = user_unsubscribe_url(id: @seller.secure_external_id(scope: "email_unsubscribe"), email_type: :seller_update)
    @subject = "Your last week."
  end

  # The three rejection kinds need opposite advice — correct the value, use a different account,
  # or wait — so the kind has to reach the template rather than being flattened to one message.
  def invalid_bank_account(user_id, rejection_kind = nil, stripe_error_message = nil)
    @seller = User.find(user_id)
    @format_rejected = rejection_kind.to_s == StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT
    # A block-listed account is the third case, and the only one where re-entering the SAME
    # details is guaranteed to fail: the details are valid, our payment partner just refuses
    # this particular account. Telling these sellers to check for typos or to wait is what
    # kept one of them re-saving a correct account for three months (gumroad-private#1476).
    @account_blocked = rejection_kind.to_s == StripeMerchantAccountManager::BANK_REJECTION_KIND_BLOCKED
    @terminal_rejected = rejection_kind.to_s == StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL
    @expected_format_hint = expected_bank_code_format_hint(stripe_error_message) if @format_rejected
    # The default branch below is the directory-miss case, whose Stripe message names neither the
    # value it refused nor which box it came from. Quote the values back so the seller can check
    # the right one (gumroad-private#1550).
    if !@account_blocked && !@format_rejected && !@terminal_rejected
      @directory_miss_detail = StripeMerchantAccountManager.bank_directory_miss_detail(@seller.active_bank_account)
    end
    @subject = if @account_blocked
      "Please add a different bank account for payouts."
    elsif @format_rejected
      "Your bank details need correcting for payouts."
    elsif @terminal_rejected
      "We need a different bank account for your payouts."
    else
      "We couldn't verify your bank account yet."
    end
  end

  def invalid_account_holder_name(user_id)
    @seller = User.find(user_id)
    @country_code = @seller.alive_user_compliance_info&.legal_entity_country_code
    @subject = "Your bank account holder name was rejected."
  end

  def cannot_pay(payment_id)
    @payment = Payment.find(payment_id)
    @seller = @payment.user
    @subject = "We were unable to pay you."
    @amount = Money.new(@payment.amount_cents, @payment.currency).format(no_cents_if_whole: true, symbol: true)
  end

  def flagged_for_explicit_nsfw_tos_violation(user_id)
    @seller = User.find(user_id)
    @subject = "Your account has been temporarily suspended for selling sexually explicit / fetish-related content"
    @days_until_suspension = 10
    date_of_suspension = Time.current + @days_until_suspension.days
    @formatted_suspension_date = I18n.l(date_of_suspension, format: "%-d %B", locale: @seller.locale)
    @from = NOREPLY_EMAIL_WITH_NAME
  end

  def debit_card_limit_reached(payment_id)
    @payment = Payment.find(payment_id)
    @seller = @payment.user
    @subject = "We were unable to pay you."
    @amount = Money.new(@payment.amount_cents, @payment.currency).format(no_cents_if_whole: true, symbol: true)
    @limit = Money.new(StripePayoutProcessor::DEBIT_CARD_PAYOUT_MAX, Currency::USD).format(no_cents_if_whole: true, symbol: true)
  end

  def subscription_product_deleted(link_id)
    @product = Link.find(link_id)
    @seller = @product.user
    @subject =
      if @product.is_recurring_billing?
        "Subscriptions have been canceled"
      else
        "Installment plans have been canceled"
      end
  end

  def credit_notification(user_id, amount_cents, reason = nil)
    @seller = User.find_by(id: user_id)
    @amount = Money.new(amount_cents * get_rate(@seller.currency_type).to_f, @seller.currency_type.to_sym).format(no_cents_if_whole: true, symbol: true)
    @reason = reason
    @subject = "You've received Gumroad credit!"
  end

  def gumroad_day_credit_notification(user_id, amount_cents)
    @seller = User.find_by(id: user_id)
    @amount = Money.new(amount_cents * get_rate(@seller.currency_type).to_f, @seller.currency_type.to_sym).format(no_cents_if_whole: true, symbol: true)
    @subject = "You've received Gumroad credit!"
  end

  def subscription_cancelled(subscription_id)
    @subscription = Subscription.find(subscription_id)
    @seller = @subscription.seller
    @subject =
      if @subscription.is_installment_plan?
        "An installment plan has been canceled."
      else
        "A subscription has been canceled."
      end
  end

  def subscription_cancelled_by_customer(subscription_id)
    @subscription = Subscription.find(subscription_id)
    @seller = @subscription.seller
    @subject = "A subscription has been canceled."
  end

  def subscription_autocancelled(subscription_id)
    @subscription = Subscription.find(subscription_id)
    @subject =
      if @subscription.is_installment_plan?
        "An installment plan has been paused."
      else
        "A subscription has been canceled."
      end
    @seller = @subscription.seller
    @last_failed_purchase = @subscription.purchases.failed.last
  end

  def subscription_ended(subscription_id)
    @subscription = Subscription.find(subscription_id)
    @seller = @subscription.seller
    @subject =
      if @subscription.is_installment_plan?
        "An installment plan has been paid in full."
      else
        "A subscription has ended."
      end
  end

  def subscription_downgraded(subscription_id, plan_change_id)
    @subscription = Subscription.find(subscription_id)
    @subscription_plan_change = SubscriptionPlanChange.find(plan_change_id)
    @seller = @subscription.seller
    @subject = "A subscription has been downgraded."
  end

  def subscription_restarted(subscription_id)
    @subscription = Subscription.find(subscription_id)
    @seller = @subscription.seller
    @subject =
      if @subscription.is_installment_plan?
        "An installment plan has been restarted."
      else
        "A subscription has been restarted."
      end
  end

  def unremovable_discord_member(discord_user_id, discord_server_name, purchase_id)
    @purchase = Purchase.find(purchase_id)
    @seller = @purchase.seller
    @discord_user_id = discord_user_id
    @discord_server_name = discord_server_name
    @subject = "We were unable to remove a Discord member from your server"
  end

  def unstampable_pdf_notification(link_id)
    @product = Link.find(link_id)
    @seller = @product.user
    @subject = "We were unable to stamp your PDF"
  end

  def chargeback_lost_no_refund_policy(dispute_id)
    dispute = Dispute.find(dispute_id)
    @disputable = dispute.disputable
    @seller = @disputable.seller
    @subject = "A dispute has been lost"
  end

  def chargeback_won(dispute_id)
    dispute = Dispute.find(dispute_id)
    @disputable = dispute.disputable
    @seller = @disputable.seller
    @subject = "A dispute has been won"
  end

  def preorder_release_reminder(link_id)
    @product = Link.find(link_id)
    @preorder_link = @product.preorder_link
    @seller = @product.user
    @subject = "Your pre-order will be released shortly"
  end

  def preorder_summary(preorder_link_id)
    preorder_link = PreorderLink.find_by(id: preorder_link_id)
    @product = preorder_link.link

    @revenue_cents = preorder_link.revenue_cents
    @preorders_count = preorder_link.preorders.authorization_successful_or_charge_successful.count
    @preorders_charged_successfully_count = preorder_link.preorders.charge_successful.count
    @failed_preorder_emails = Purchase.where("preorder_id IN (?)", preorder_link.preorders.authorization_successful.pluck(:id)).group(:preorder_id).pluck(:email)

    # Don't send the email if the seller made no money.
    return do_not_send if @preorders_charged_successfully_count == 0

    @seller = @product.user
    @subject = "Your pre-order was successfully released!"
  end

  def preorder_cancelled(preorder_id)
    @preorder = Preorder.find_by(id: preorder_id)
    @seller = @preorder.seller
    @subject = "A preorder has been canceled."
  end

  def purchase_refunded_for_fraud(purchase_id)
    @purchase = Purchase.find_by(id: purchase_id)
    @seller = @purchase.seller
    @subject = "Fraud was detected on your Gumroad account."
  end

  # refund_id is optional: when the refund carries a note (the reason a team member
  # entered when refunding on the creator's behalf), the email shows it so the creator
  # knows why the sale was refunded without having to write in to support.
  def purchase_refunded(purchase_id, refund_id = nil)
    @purchase = Purchase.find_by(id: purchase_id)
    @seller = @purchase.seller
    @refund_reason = Refund.find_by(id: refund_id)&.note
    @subject = "A sale has been refunded"
  end

  def payment_returned(payment_id)
    @payment = Payment.find(payment_id)
    @seller = @payment.user
    @subject = "Gumroad payout returned"
  end

  def payouts_may_be_blocked(user_id)
    @seller = User.find(user_id)
    return do_not_send unless @seller.account_active?
    @subject = "We need more information from you."
  end

  def payout_setup_retry_exhausted(user_id, marker_type)
    @seller = User.find(user_id)
    return do_not_send unless @seller.account_active?
    @marker_type = marker_type.to_s
    @subject = @marker_type == "bank" ? "We still couldn't verify your bank account." : "We still couldn't verify your postal code."
  end

  def more_kyc_needed(user_id, fields_needed = [])
    @seller = User.find(user_id)
    return do_not_send unless @seller.account_active?
    @subject = "We need more information from you."
    country = @seller.compliance_country_code
    @fields_needed_tags = fields_needed.map { |field_needed| UserComplianceInfoFieldProperty.name_tag_for_field(field_needed, country:) }.compact
  end

  def stripe_document_verification_failed(user_id, error_message)
    @seller = User.find(user_id)
    return do_not_send unless @seller.account_active?
    @subject = "[Action Required] Stripe needs an updated document"
    @error_message = error_message
    @error_message_is_unactionable = UserComplianceInfoRequest.unactionable_verification_message?(error_message)
  end

  def stripe_identity_verification_failed(user_id, error_message)
    @seller = User.find(user_id)
    return do_not_send unless @seller.account_active?
    @subject = "[Action Required] Stripe needs updated identity information"
    @error_message = error_message
    @error_message_is_unactionable = UserComplianceInfoRequest.unactionable_verification_message?(error_message)
  end

  def singapore_identity_verification_reminder(user_id, deadline)
    @seller = User.find(user_id)
    return do_not_send unless @seller.account_active?
    @deadline = deadline.to_fs(:formatted_date_full_month)
    @subject = "[Action Required] Complete the identity verification to avoid account closure"
  end

  def stripe_remediation(user_id)
    @seller = User.find(user_id)
    return do_not_send unless @seller.account_active?
    @subject = "We need more information from you."
  end

  def suspended_due_to_stripe_risk(user_id)
    @seller = User.find(user_id)
    @subject = "Your account has been suspended for being high risk"
  end

  def user_sales_data(user_id, sales_csv_tempfile)
    @seller = User.find(user_id)
    @subject = "Here's your customer data!"
    file_or_url = MailerAttachmentOrLinkService.new(
      file: sales_csv_tempfile,
      extension: "csv",
      filename: "user-sales-data/Sales_#{user_id}_#{Time.current.strftime("%s")}_#{SecureRandom.hex}.csv"
    ).perform
    file = file_or_url[:file]
    if file
      file.rewind
      attachments["sales_data.csv"] = { data: file.read }
    else
      @sales_csv_url = file_or_url[:url]
    end
  end

  def tax_form_transaction_report(user_id, year, csv_tempfile)
    @seller = User.find(user_id)
    @year = year
    @subject = "Your #{year} 1099-K transaction report"
    file_or_url = MailerAttachmentOrLinkService.new(
      file: csv_tempfile,
      extension: "csv",
      filename: "1099k-transaction-reports/1099-K-transactions_#{year}_#{user_id}_#{SecureRandom.hex}.csv"
    ).perform
    file = file_or_url[:file]
    if file
      file.rewind
      attachments["1099-K-transactions-#{year}.csv"] = { data: file.read }
    else
      @report_csv_url = file_or_url[:url]
    end
  end

  def payout_data(attachment_name, extension, tempfile, recipient_user_id)
    @recipient = User.find(recipient_user_id)
    @subject = "Here's your payout data!"

    file_or_url = MailerAttachmentOrLinkService.new(
      file: tempfile,
      filename: attachment_name,
      extension:
    ).perform

    if file = file_or_url[:file]
      file.rewind
      attachments[attachment_name] = file.read
    else
      @payout_data_url = file_or_url[:url]
    end
  end

  def annual_payout_summary(user_id, year, total_amount)
    @year = year
    @next_year = Date.new(year).next_year.year
    @formatted_total_amount = formatted_dollar_amount((total_amount * 100).floor)
    @seller = User.find(user_id)
    @subject = "Here's your financial report for #{year}!"
    @link = @seller.financial_annual_report_url_for(year:)
    do_not_send unless @link.present?
  end

  def tax_form_1099k(user_id, year)
    @seller = User.find(user_id)
    @year = year
    @is_filed = @seller.user_tax_forms.for_year(year).where(tax_form_type: "us_1099_k").first&.filed?
    @subject = "Get your 1099-K form for #{@year}"
  end

  def tax_form_1099misc(user_id, year)
    @seller = User.find(user_id)
    @year = year
    @subject = "Get your 1099-MISC form for #{@year}"
  end

  def video_transcode_failed(product_file_id)
    @subject = "A video failed to transcode."
    product_file = ProductFile.find(product_file_id)
    return do_not_send if product_file.link.nil?

    @video_transcode_error = "We attempted to transcode a video (#{product_file.s3_filename}) from your product #{product_file.link.name}, but were unable to do so."
    @seller = product_file.user
  end

  def affiliates_data(recipient:, tempfile:, filename:)
    @subject = "Here is your affiliates data!"
    @recipient = recipient
    file_or_url = MailerAttachmentOrLinkService.new(
      file: tempfile,
      filename:,
    ).perform
    if file_or_url[:file]
      file_or_url[:file].rewind
      attachments[filename] = { data: file_or_url[:file].read }
    else
      @affiliates_file_url = file_or_url[:url]
    end
  end

  def subscribers_data(recipient:, tempfile:, filename:)
    @subject = "Here is your subscribers data!"
    @recipient = recipient
    file_or_url = MailerAttachmentOrLinkService.new(
      file: tempfile,
      filename:,
    ).perform
    if file_or_url[:file]
      file_or_url[:file].rewind
      attachments[filename] = { data: file_or_url[:file].read }
    else
      @subscribers_file_url = file_or_url[:url]
    end
  end

  def review_submitted(review_id)
    @review = ProductReview.includes(:purchase, link: :user).find(review_id)
    @product = @review.link
    @seller = @product.user
    full_name = @review.purchase.full_name
    email = @review.purchase.email
    @buyer = full_name.present? ? "#{full_name} (#{email})" : email
    @subject = "#{@buyer} reviewed #{@product.name}"
  end

  def upcoming_call_reminder(call_id)
    call = Call.find(call_id)
    return do_not_send unless call.eligible_for_reminder?

    purchase = call.purchase
    @seller = purchase.seller
    buyer_email = purchase.purchaser_email_or_email
    @subject = "Your scheduled call with #{buyer_email} is tomorrow!"

    @post_purchase_custom_fields_attributes = purchase.purchase_custom_fields
      .where.not(field_type: CustomField::TYPE_FILE)
      .map { { label: _1.name, value: _1.value } }

    @customer_information_attributes = [
      { label: "Customer email", value: buyer_email },
      { label: "Call schedule", value: [call.formatted_time_range, call.formatted_date_range] },
      { label: "Duration", value: purchase.variant_names.first },
      call.call_url ? { label: "Call link", value: call.call_url } : nil,
      { label: "Product", value: purchase.link.name }
    ].compact
  end

  def refund_policy_enabled_email(seller_id)
    @seller = User.find(seller_id)
    @subject = "Important: Refund policy changes to your account"
    @postponed_date = User::LAST_ALLOWED_TIME_FOR_PRODUCT_LEVEL_REFUND_POLICY + 1.second if @seller.account_level_refund_policy_delayed?
    @subject += " (effective #{@postponed_date.to_fs(:formatted_date_full_month)})" if @postponed_date.present?
  end

  def refund_policy_enforced_notification(seller_id)
    @seller = User.find(seller_id)
    return do_not_send unless @seller.account_active?
    @subject = "Important: Your refund policy has been updated"
  end

  def product_level_refund_policies_reverted(seller_id)
    @seller = User.find(seller_id)
    @subject = "Important: Refund policy changes effective immediately"
  end

  def upcoming_refund_policy_change(user_id)
    @seller = User.find(user_id)
    @subject = "Important: Upcoming refund policy changes effective January 1, 2025"
  end

  def paypal_suspension_notification(user_id)
    @seller = User.find(user_id)
    @subject = "Important: Update Your Payout Method on Gumroad"
  end

  private
    # Stripe's format-rejection messages end with the format it expects, for example:
    # "Invalid routing number for PK. The number must contain both the bank code and the branch
    # code, and should be in the format AAAAPKBB or AAAAPKBBXYZ." Pull out that sentence so the
    # email can show the seller exactly what shape their code needs, without echoing the raw
    # error (which starts by naming a "routing number" that most sellers won't recognize).
    #
    # The word boundary matters: without it "information" matches, and Stripe's generic
    # "Please double-check the information provided and try again." would be presented to the
    # seller as the format their bank expects. Anything implausibly long isn't the terse format
    # sentence we're after either, so drop it rather than pasting a wall of text into the email.
    MAX_FORMAT_HINT_LENGTH = 200

    def expected_bank_code_format_hint(stripe_error_message)
      message = stripe_error_message.to_s
      sentence = message.split(/(?<=\.)\s+/).find { |part| part.match?(/\bformats?\b/i) }&.strip
      return if sentence.blank? || sentence.length > MAX_FORMAT_HINT_LENGTH

      sentence
    end

    def do_not_send
      @do_not_send = true
    end

    def should_send_email?
      return true unless @purchase

      if @purchase.price_cents == 0
        @seller.enable_free_downloads_email?
      elsif @purchase.is_recurring_subscription_charge && !@purchase.is_upgrade_purchase?
        @seller.enable_recurring_subscription_charge_email?
      else
        @seller.enable_payment_email?
      end
    end

    def push_notification_enabled?
      return true unless @purchase

      if @purchase.price_cents == 0
        @seller.enable_free_downloads_push_notification?
      elsif @purchase.is_recurring_subscription_charge && !@purchase.is_upgrade_purchase?
        @seller.enable_recurring_subscription_charge_push_notification?
      else
        @seller.enable_payment_push_notification?
      end
    end

    def deliver_email
      return if @do_not_send

      recipient = @recipient || @seller
      email = recipient.form_email
      return unless EmailFormatValidator.valid?(email)

      mailer_args = { to: email, subject: @subject }
      mailer_args[:reply_to] = @reply_to if @reply_to.present?
      mailer_args[:from] = @from if @from.present?
      mail(mailer_args)
    end

    def send_push_notification!
      return unless push_notification_enabled?

      if Feature.active?(:send_sales_notifications_to_creator_app)
        PushNotificationWorker.perform_async(@seller.id, Device::APP_TYPES[:creator], @subject, nil, {}, Device::NOTIFICATION_SOUNDS[:sale])
      end

      if Feature.active?(:send_sales_notifications_to_consumer_app)
        PushNotificationWorker.perform_async(@seller.id, Device::APP_TYPES[:consumer], @subject, nil, {}, Device::NOTIFICATION_SOUNDS[:sale])
      end
    end
end
