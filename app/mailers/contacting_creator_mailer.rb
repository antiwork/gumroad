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
  # `around` rather than `after`, because the notice claimed at render has to be given back on every
  # path where nothing was sent — including a delivery that raises, which an after callback never sees.
  # It runs for every action on this mailer, and the ivar check inside is what scopes it: an `only:`
  # here would be accepted and silently ignored, since deliver callbacks take `:if`/`:unless` only.
  around_deliver :settle_undeliverable_ping_subscription_notice
  around_deliver :settle_undelivered_receipts_notice
  around_deliver :settle_review_notification

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
        due_at = format_dispute_evidence_due_at(dispute_evidence.seller_response_due_at)
        safe_join(
          [
            tag.p(tag.b("Any additional information you can provide by #{due_at} (in the next #{pluralize(hours_left, "hour")}) will help us win on your behalf.")),
            tag.p(
              link_to(
                "Submit additional information",
                purchase_dispute_evidence_url(
                  @disputable.purchase_for_dispute_evidence.secure_external_id(
                    scope: Purchases::DisputeEvidenceController::SECURE_ID_SCOPE,
                    expires_at: dispute_evidence.evidence_link_expires_at
                  )
                ),
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

  def chargeback_evidence_due_soon(dispute_id)
    dispute = Dispute.find(dispute_id)
    @disputable = dispute.disputable
    @seller = @disputable.seller
    @dispute_evidence = dispute.dispute_evidence
    return do_not_send unless @dispute_evidence&.accepting_evidence?

    @hours_left = @dispute_evidence.hours_left_to_submit_evidence
    return do_not_send unless @hours_left.positive?

    @seller_response_due_at_formatted = format_dispute_evidence_due_at(@dispute_evidence.seller_response_due_at)
    @subject = "Reminder: Submit dispute evidence within 24 hours"
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
  #
  # bank_account_id names the row Stripe actually refused. The mail renders asynchronously, and a
  # seller who re-saves while the rejection is in flight would otherwise be shown their newest
  # values under "the details we sent" — values that were never sent (gumroad-private#1550).
  def invalid_bank_account(user_id, rejection_kind = nil, stripe_error_message = nil, bank_account_id = nil)
    @seller = User.find(user_id)
    @format_rejected = rejection_kind.to_s == StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT
    # A block-listed account is the third case, and the only one where re-entering the SAME
    # details is guaranteed to fail: the details are valid, our payment partner just refuses
    # this particular account. Telling these sellers to check for typos or to wait is what
    # kept one of them re-saving a correct account for three months (gumroad-private#1476).
    @account_blocked = rejection_kind.to_s == StripeMerchantAccountManager::BANK_REJECTION_KIND_BLOCKED
    @terminal_rejected = rejection_kind.to_s == StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL
    @expected_format_hint = expected_bank_code_format_hint(stripe_error_message) if @format_rejected
    # Gated on the message rather than on "no kind was classified": an unclassified rejection is
    # not necessarily a directory miss (a declined debit card and a bank-country mismatch both
    # arrive here with no kind), and quoting routing values at those sellers points them at a
    # field that had nothing to do with the failure.
    if StripeMerchantAccountManager.bank_details_directory_miss_message?(stripe_error_message)
      @directory_miss_detail = StripeMerchantAccountManager.bank_directory_miss_detail(
        rejected_bank_account(bank_account_id)
      )
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

  # PayPal refused a payout for a reason about the seller's PayPal account rather than the attempt:
  # their country cannot receive PayPal payments (3148), or the account cannot receive US dollars
  # (14159). Either way nothing will change until they act, so this email says what is wrong and
  # what to change — otherwise their balance just sits there.
  #
  # The two cases differ in what is true about the retries, and the copy has to match: 3148 stops
  # them, 14159 does not (see Payment::FailureReason::RETRY_BLOCKING_PAYPAL_FAILURE_REASONS).
  def paypal_payout_permanently_failed(payment_id)
    @payment = Payment.find(payment_id)
    @seller = @payment.user
    @subject = "Your PayPal account can't receive your payout."
    @amount = Money.new(@payment.amount_cents, @payment.currency).format(no_cents_if_whole: true, symbol: true)
    @reason = Payment::FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_REASONS.fetch(
      @payment.failure_reason,
      # Reached by the mailer preview, which renders against whatever payout rows the local
      # database happens to have. It is also the safety net if this mailer is ever enqueued for a
      # payment whose failure_reason is not one we explain — the copy would then name the wrong
      # restriction, so keep the caller gated on Payment#explained_paypal_failure?.
      Payment::FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_REASONS.values.first
    )
    # Never claim the retries have stopped unless they have. A seller rejected for the currency
    # keeps being paid on schedule, and telling them otherwise would be false and would push them
    # to change accounts when they do not have to.
    @retries_stopped = @payment.terminal_paypal_failure?
    @no_payout_rail_available = @payment.paypal_failure_without_available_payout_rail?
    # ...and never promise a retry that a pause is already stopping. Payouts.is_user_payable exits
    # on the broader payouts_paused? long before any processor runs, so for a paused seller "we'll
    # keep trying on your usual payout schedule" is false and contradicts the pause this same email
    # goes on to describe. Covers both a hold we placed and the seller's own toggle.
    @retries_paused_by_pause = !@retries_stopped && @seller.payouts_paused?
    # And when they can clear it on the account they already have, lead with that fix.
    @can_receive_us_dollars_on_same_account = @payment.repairable_in_place_paypal_failure?
    # A locked or inactive receiving account needs its own fix copy: only PayPal can lift it, and
    # the country-based alternatives below are the wrong diagnosis for it (gumroad-private#1661).
    @locked_paypal_account = @payment.locked_account_paypal_failure?
    # Ask the seller to reply rather than promising the next payout date, because an admin or
    # system hold outlives the payout-method fix this email prescribes and only support can lift
    # it. A hold Stripe placed is lifted automatically when the seller changes their payout details
    # (UpdatePayoutMethod), so for them the ask is merely over-cautious rather than wrong. A seller
    # who paused their own payouts is pointed at their own toggle instead of at support. Both flags
    # are read independently because both can be on: the template names each one it finds, since
    # clearing only the hold still leaves the seller's own pause stopping the money, and they
    # cannot be told plainly to expect the next payout date either — the payout gate checks the
    # broader payouts_paused? and skips them while either is on.
    @payouts_on_hold = @seller.payouts_paused_internally?
    @payouts_paused_by_seller = @seller.payouts_paused_by_user?
    # Bank transfer is not offered everywhere. Most sellers who hit these rejections are in
    # PayPal-only countries, where "add a bank account" is advice they cannot act on.
    @can_use_bank_account = @seller.can_setup_bank_payouts?
    # Whether we actually removed their PayPal address, which the copy below claims. Not every
    # retry-blocking rejection removes one — a seller paid through a connected PayPal account has no
    # saved address for us to take away, and saying we took it would be false.
    @payout_address_removed = @payment.paypal_payout_address_invalidated?
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

  # The two reasons need opposite advice — fill in a URL, or re-authorize the app that owns the
  # subscription — so the reason is resolved here rather than flattened into one vague message.
  # Everything this send depends on is read here rather than passed in: the subscription is enqueued
  # from the sale path and rendered from the low queue, and inside that window the seller can delete
  # it, repair it, or break it a different way. The send-once notice is claimed here and settled after
  # delivery, by `settle_undeliverable_ping_subscription_notice`.
  def undeliverable_ping_subscription(resource_subscription_id)
    @resource_subscription = ResourceSubscription.alive.find_by(id: resource_subscription_id)
    # Saying it is "still listed as active" would be false for a subscription deleted in the window.
    return do_not_send if @resource_subscription.nil?

    @seller = @resource_subscription.user
    return do_not_send if @seller.nil?

    # Setting a URL or re-authorizing the app makes it deliverable again, and this email would then
    # ask the seller to repair something already working. A disconnect in the same window soft-deletes
    # the application, which is not deliverable either but is also not the seller's to fix.
    return do_not_send if @seller.ping_notification_deliverable?(@resource_subscription)
    return do_not_send unless @seller.ping_notification_notice_actionable?(@resource_subscription)

    rendered_reason = UndeliverablePingSubscriptionNotifier.reason_for(@resource_subscription)
    # Claiming rather than checking: the enqueue throttle is keyed on the reason as it was at enqueue,
    # so two jobs that resolve to the same reason here are not excluded by it and a read would let both
    # send. Nothing below can decline, so the claim marks a send this render is committed to.
    claim_token = UndeliverablePingSubscriptionNotifier.claim_send(resource_subscription_id, rendered_reason)
    return do_not_send if claim_token.nil?

    @undeliverable_ping_subscription_claim_token = claim_token
    @undeliverable_ping_subscription_reason = rendered_reason
    @application_name = @resource_subscription.oauth_application&.name
    @missing_post_url = rendered_reason == UndeliverablePingSubscriptionNotifier::MISSING_POST_URL
    @subject = "Your #{@resource_subscription.resource_name} webhook is not being sent"
  end

  # `purchase_ids` is everything the sweep found for this seller, untruncated: the list is cut down
  # here, after the recheck, so that buyers who recovered cannot crowd out one who did not.
  def undelivered_receipts(seller_id, purchase_ids)
    @seller = User.alive.find_by(id: seller_id)
    return do_not_send if @seller.nil?

    # Re-judged here rather than trusted from the sweep: a buyer can open their content in the gap
    # between the scan and this render, and then this email would tell the seller to chase someone who
    # already has what they paid for.
    still_affected = Purchase.where(id: purchase_ids).includes(:link, :url_redirect).select do |purchase|
      UndeliveredReceiptNotifier.undelivered?(purchase)
    end
    return do_not_send if still_affected.empty?

    # Claimed rather than checked, and settled after delivery by
    # `settle_undelivered_receipts_notice`: the sweep's read cannot separate two renders of the same
    # buyer, and the job's own retry re-collects these rows before any mail has gone out.
    claimed = UndeliveredReceiptNotifier.claim_send(still_affected.map(&:id)).to_set
    still_affected.select! { |purchase| claimed.include?(purchase.id) }
    return do_not_send if still_affected.empty?

    @undelivered_receipt_purchase_ids = still_affected.map(&:id)
    # The count is what the seller acts on: it counts everyone this email stands behind, listed or
    # summarized, and never the sweep's figure from before the recheck.
    @total = still_affected.size
    @purchases = still_affected.first(UndeliveredReceiptNotifier::MAX_LISTED_PER_SELLER)
    @undisclosed_count = @total - @purchases.size
    @subject = "#{@total == 1 ? "A buyer" : "#{@total} buyers"} may not have received their receipt"
  end

  def chargeback_lost_no_refund_policy(dispute_id)
    dispute = Dispute.find(dispute_id)
    @disputable = dispute.disputable
    # Mailer jobs can render after product refund policies change.
    @product_without_refund_policy = @disputable.first_product_without_refund_policy
    return do_not_send if @product_without_refund_policy.nil?

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

  # A review notifies the seller at most once (immediately if the buyer typed before submitting,
  # otherwise via whichever of the delayed message-less render or the blank→present arrival fires
  # first). Two things enforce that: `seller_notified_at` for a send that already happened, however
  # long ago, and the claim for the overlap the marker cannot see — the delayed job's read of
  # `message` and its eventual delivery straddle the buyer's commit, so without it both paths can
  # decide to send before either has recorded one.
  #
  # The claim is taken last, so an ordinary rejection does not have to give one back.
  def review_submitted(review_id)
    @review = ProductReview.includes(:purchase, link: :user).find(review_id)
    return do_not_send if @review.deleted?
    return do_not_send if @review.seller_notified?

    @product = @review.link
    @seller = @product.user
    # Re-checked here, not just at enqueue: the delayed message-less render can still be
    # sitting in the queue when the seller flips this off, and the job's own preference
    # check at enqueue time can't see a later change.
    return do_not_send if @seller.disable_reviews_email?
    @review_notification_claim = @review.claim_seller_notification
    return do_not_send if @review_notification_claim.nil?

    name = @review.purchase.rater_identity_name
    email = @review.purchase.email
    @buyer = name.present? ? "#{name} (#{email})" : email
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

    # The row Stripe refused, and only that row. An unnamed id (a job enqueued before this
    # argument existed) resolves to nothing rather than to the active account: the seller may have
    # saved a replacement since, and quoting those values as "the details we sent" points them at
    # a row Stripe never saw. No row means no quoted values, which is the pre-existing copy.
    def rejected_bank_account(bank_account_id)
      return if bank_account_id.blank?

      @seller.bank_accounts.find_by(id: bank_account_id)
    end

    def expected_bank_code_format_hint(stripe_error_message)
      message = stripe_error_message.to_s
      sentence = message.split(/(?<=\.)\s+/).find { |part| part.match?(/\bformats?\b/i) }&.strip
      return if sentence.blank? || sentence.length > MAX_FORMAT_HINT_LENGTH

      sentence
    end

    def do_not_send
      @do_not_send = true
    end

    def format_dispute_evidence_due_at(due_at)
      due_at.in_time_zone(@seller.timezone.presence || Time.zone).strftime("%B %-d, %Y at %-l:%M %p %Z")
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

    # The render claimed the seller's one notice; this decides whether it was spent. Only a message
    # actually transmitted spends it — `deliver_email` returns before `mail` for an address we will
    # not send to, which delivers an empty message rather than raising; a transport failure raises
    # straight through here; and `perform_deliveries = false` drops the message silently, the way
    # `PostSendgridApi` already reads that flag. All three leave the seller un-notified, so all three
    # give the claim back and let a later event report it again.
    #
    # `RescueSmtpErrors` does not hide the SMTP cases from this: it handles them outside the deliver
    # callbacks, so a rejection unwinds to this `ensure` first and only then looks like a clean send.
    def settle_undeliverable_ping_subscription_notice
      delivered = false
      yield
      delivered = message.to.present? && message.perform_deliveries
    ensure
      # `ensure` rather than an after callback, so a raised delivery settles too.
      unless @resource_subscription.nil? || @undeliverable_ping_subscription_reason.blank?
        settle = delivered ? :record_sent : :release_claim
        UndeliverablePingSubscriptionNotifier.public_send(
          settle, @resource_subscription.id, @undeliverable_ping_subscription_reason,
          @undeliverable_ping_subscription_claim_token
        )
      end
    end

    # The render claimed the seller's one notice for a review; this decides whether it was spent.
    # Mirrors `settle_undeliverable_ping_subscription_notice`, including why the claim has to be
    # given back rather than left to expire: `MailDeliveryJob` retries a transient SMTP failure by
    # re-rendering the same mailer action, so a claim still held on the retry turns a delivery worth
    # retrying into a notice the seller never gets.
    def settle_review_notification
      delivered = false
      yield
      delivered = message.to.present? && message.perform_deliveries
    ensure
      # `ensure` rather than an after callback, so a raised delivery settles too.
      unless @review_notification_claim.nil?
        if delivered
          @review.record_seller_notified!
        else
          @review.release_seller_notification_claim(@review_notification_claim)
        end
      end
    end

    # The render claimed each buyer's one notice; this decides whether they were spent. Mirrors
    # `settle_undeliverable_ping_subscription_notice` — only a message actually transmitted spends a
    # claim, and a suppressed, dropped, or raised delivery gives every claim back so a later sweep can
    # report those buyers again.
    def settle_undelivered_receipts_notice
      delivered = false
      yield
      delivered = message.to.present? && message.perform_deliveries
    ensure
      # `ensure` rather than an after callback, so a raised delivery settles too.
      unless @undelivered_receipt_purchase_ids.blank?
        settle = delivered ? :record_sent : :release_claim
        UndeliveredReceiptNotifier.public_send(settle, @undelivered_receipt_purchase_ids)
      end
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
