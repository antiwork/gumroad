# frozen_string_literal: true

class Purchase
  module Refundable
    # * amount - the amount to refund (out of `Purchase#price_cents`, VAT-exclusive). VAT will be refunded proportinally to this amount.
    def refund!(refunding_user_id:, amount: nil)
      if amount.blank?
        refund_and_save!(refunding_user_id)
      else
        refund_amount_cents = refunding_amount_cents(amount)
        if refund_amount_cents > amount_refundable_cents
          errors.add :base, "Refund amount cannot be greater than the purchase price."
          false
        elsif refund_amount_cents == price_cents || refund_amount_cents == amount_refundable_cents
          # User attempted a partial refund with same amount as total purchase or
          # remaining refundable amount.
          # Short-circuit this, so we don't need to handle edge cases about taxes
          refund_and_save!(refunding_user_id)
        else
          refund_and_save!(refunding_user_id, amount_cents: refund_amount_cents)
        end
      end
    end

    # Refunds purchase through charge processor if price > 0. Is idempotent. Returns false on failure.
    # refunding_user_id can't be enforced from console, in which case it will be nil
    #
    # * amount - the amount to refund (out of `Purchase#price_cents`, VAT-exclusive). VAT will be refunded proportinally to this amount.
    def refund_and_save!(refunding_user_id, amount_cents: nil, is_for_fraud: false)
      return if stripe_transaction_id.blank? || stripe_refunded || amount_refundable_cents <= 0

      if (merchant_account.is_a_stripe_connect_account? && !merchant_account.active?) ||
          (charge_processor_id == PaypalChargeProcessor.charge_processor_id &&
              !seller_native_paypal_payment_enabled?)
        errors.add :base, "We cannot refund this sale because you have disconnected the associated payment account on " \
                        "#{charge_processor_id.titleize}. Please connect it and try again."
        return false
      end

      if refunding_user_id.blank? || !User.find(refunding_user_id)&.is_team_member?
        if seller.refunds_disabled?
          errors.add :base, "Refunds are temporarily disabled in your account."
          return false
        end

        amount_cents_to_refund = amount_cents.presence || amount_refundable_cents
        if amount_cents_to_refund > seller.unpaid_balance_cents && charged_using_gumroad_merchant_account?
          errors.add :base, "Your balance is insufficient to process this refund."
          return false
        end
      end

      begin
        logger.info("Refunding purchase: #{id} and amount_cents: #{amount_cents} , amount_refundable_cents: #{amount_refundable_cents}")

        # In case of combined charge with multiple purchases, if amount_cents is absent i.e. it is a full refund,
        # set amount cents equal to refundable_amount_cents
        # which would be price_cents if no partial refund has been issued yet
        # This would make a partial refund equal to amount cents on the Stripe/PayPal charge,
        # as without amount_cents set, Stripe/PayPal would refund the entire charge which contains multiple purchases
        if is_part_of_combined_charge? && charge&.purchases&.many? && amount_cents.blank?
          amount_cents = amount_refundable_cents
        end

        # If this is a partial refund and we have previously charged VAT, calculate a proportional amount of VAT to refund in addition to `amount_cents`
        gross_amount_cents = if amount_cents.present? && gumroad_responsible_for_tax?
          proportional_tax_cents = (amount_cents * gumroad_tax_cents / price_cents.to_f).floor
          # Some VAT could have been refunded separately from the purchase price and we may not have enough refundable VAT left
          tax_cents = [proportional_tax_cents, gumroad_tax_refundable_cents].min
          amount_cents + tax_cents
        else
          amount_cents
        end

        paypal_order_purchase_unit_refund = true if paypal_order_id
        charge_refund = ChargeProcessor.refund!(charge_processor_id,
                                                stripe_transaction_id,
                                                amount_cents: gross_amount_cents,
                                                merchant_account:,
                                                reverse_transfer: !chargedback? || !chargeback_reversed,
                                                paypal_order_purchase_unit_refund:,
                                                is_for_fraud:)
        logger.info("Refunding purchase: #{id} completed with ID: #{charge_refund.id}, Flow of Funds: #{charge_refund.flow_of_funds.to_h}")
        purchase_event = Event.where(purchase_id: id, event_name: "purchase").last
        unless purchase_event.nil?
          Event.create(
            event_name: "refund",
            purchase_id: purchase_event.purchase_id,
            browser_fingerprint: purchase_event.browser_fingerprint,
            ip_address: purchase_event.ip_address
          )
        end

        if charge_refund.flow_of_funds.nil? && StripeChargeProcessor.charge_processor_id != charge_processor_id
          charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -(gross_amount_cents.presence || gross_amount_refundable_cents))
        end
        refund_purchase!(charge_refund.flow_of_funds, refunding_user_id, charge_refund.refund, is_for_fraud)
      rescue ChargeProcessorAlreadyRefundedError => e
        logger.error "Charge was already refunded in purchase: #{external_id}. Response: #{e.message}"
        false
      rescue ChargeProcessorInsufficientFundsError => e
        logger.error "Creator's PayPal account does not have sufficient funds to refund purchase: #{external_id}. Response: #{e.message}"
        errors.add :base, "Your PayPal account does not have sufficient funds to make this refund."
        false
      rescue ChargeProcessorInvalidRequestError => e
        logger.error "Charge refund encountered an invalid request error in purchase: #{external_id}. Response: #{e.message}. #{e.backtrace_locations}"
        false
      rescue ChargeProcessorUnavailableError => e
        logger.error "Charge processor unavailable in purchase: #{external_id}. Response: #{e.message}"
        errors.add :base, "There is a temporary problem. Try to refund later."
        false
      end
    end

    def build_refund(gross_refund_amount: nil, refunding_user_id:)
      if stripe_partially_refunded_was && stripe_refunded
        build_partial_full_refund(refunding_user_id:)
      elsif gross_refund_amount == total_transaction_cents
        build_full_refund(refunding_user_id:)
      else
        build_partial_refund(gross_refund_amount: (gross_refund_amount || gross_amount_refundable_cents),
                             refunding_user_id:)
      end
    end

    # Short-circuit when we want to refund full amount
    def build_full_refund(refunding_user_id:)
      Refund.new(total_transaction_cents:,
                 amount_cents: price_cents,
                 creator_tax_cents: tax_cents,
                 fee_cents:,
                 gumroad_tax_cents: gumroad_tax_refundable_cents,
                 refunding_user_id:)
    end

    # Short-circuit when we want to refund fully remaining amount
    def build_partial_full_refund(refunding_user_id:)
      new_refund_params = refundable_amounts
      return nil unless new_refund_params
      new_refund_params[:refunding_user_id] = refunding_user_id
      new_refund = Refund.new(new_refund_params)
      if new_refund.total_transaction_cents.negative? || new_refund.amount_cents.negative?
        nil
      else
        new_refund
      end
    end

    def build_partial_refund(gross_refund_amount: nil, refunding_user_id:)
      return nil if gross_refund_amount <= 0
      return nil if gross_refund_amount > gross_amount_refundable_cents

      creator_tax_cents_refunded = 0
      gumroad_tax_cents_refunded = 0
      refund_amount_cents = gross_refund_amount

      if gumroad_responsible_for_tax? && gumroad_tax_refundable_cents > 0
        tax_rate = gumroad_tax_cents / total_transaction_cents.to_f
        tax_refund_amount = (gross_refund_amount * tax_rate).floor

        # VAT could have been refunded separately from the purchase price (`Purchase#refund_gumroad_taxes!`) and we may not have enough refundable VAT left
        gumroad_tax_cents_refunded = [tax_refund_amount, gumroad_tax_refundable_cents].min
        refund_amount_cents = gross_refund_amount - gumroad_tax_cents_refunded
      end

      if seller_responsible_for_tax?
        tax_rate = tax_cents / total_transaction_cents.to_f
        creator_tax_cents_refunded = (gross_refund_amount * tax_rate).floor
      end

      fee_refund_cents = ((fee_cents.to_f / price_cents.to_f) * refund_amount_cents).floor

      Refund.new(total_transaction_cents: gross_refund_amount,
                 amount_cents: refund_amount_cents,
                 fee_cents: fee_refund_cents,
                 creator_tax_cents: creator_tax_cents_refunded,
                 gumroad_tax_cents: gumroad_tax_cents_refunded,
                 refunding_user_id:)
    end
  end

  # refunding_user_id can't be enforced from console (no current user), in which case it will be nil
  def refund_purchase!(flow_of_funds, refunding_user_id, stripe_refund = nil, is_for_fraud = false)
    funds_refunded = flow_of_funds.issued_amount.cents.abs
    partially_refunded_previously = self.stripe_partially_refunded
    ActiveRecord::Base.transaction do
      self.stripe_refunded = (gross_amount_refunded_cents + funds_refunded) >= total_transaction_cents
      self.stripe_partially_refunded = !self.stripe_refunded

      vat_already_refunded = gumroad_tax_cents > 0 && gumroad_tax_cents == gumroad_tax_refunded_cents

      refund = build_refund(gross_refund_amount: funds_refunded, refunding_user_id:)

      unless refund.present?
        logger.error "Failed creating a refund: #{self.inspect} :: flow_of_funds :: #{flow_of_funds.inspect} :: stripe_refund :: #{stripe_refund}"
        errors.add :base, "The purchase could not be refunded. Please check the refund amount."
        return false
      end

      if stripe_refund
        refund.status = stripe_refund.status
        refund.processor_refund_id = stripe_refund.id
      end
      refund.is_for_fraud = is_for_fraud
      refunds << refund
      self.is_refund_chargeback_fee_waived = !charged_using_gumroad_merchant_account? || is_for_fraud
      mark_giftee_purchase_as_refunded(is_partially_refunded: self.stripe_partially_refunded?) if is_gift_sender_purchase
      subscription.cancel_immediately_if_pending_cancellation! if subscription.present?
      decrement_balance_for_refund_or_chargeback!(flow_of_funds, refund:)
      save!
      reverse_the_transfer_made_for_dispute_win! if chargedback? && chargeback_reversed
      reverse_excess_amount_from_stripe_transfer(refund:) if stripe_partially_refunded && vat_already_refunded
      debit_processor_fee_from_merchant_account!(refund) unless is_refund_chargeback_fee_waived
      Credit.create_for_vat_exclusive_refund!(refund:) if paypal_order_id.present? || merchant_account&.is_a_stripe_connect_account?
      subscription.original_purchase.update!(should_exclude_product_review: true) if subscription&.should_exclude_product_review_on_charge_reversal?
      send_refunded_notification_webhook
      if partially_refunded_previously || self.stripe_partially_refunded
        CustomerMailer.partial_refund(email, link.id, id, funds_refunded, formatted_refund_state).deliver_later(queue: "critical")
      else
        CustomerMailer.refund(email, link.id, id).deliver_later(queue: "critical")
      end
      # Those callbacks are manually invoked because of a rails issue: https://github.com/rails/rails/issues/39972
      update_creator_analytics_cache(force: true)
      # Refunding impacts many of the ES document fields,
      # including but not limited to: amount_refunded_cents, fee_refunded_cents, affiliate_credit.*, etc.
      # Reindexing the entire document is simpler, and future-proof with regards to new fields added later.
      send_to_elasticsearch("index")

      enqueue_update_sales_related_products_infos_job(false)

      unless refund.user&.is_team_member?
        # Check for low balance and put the creator on probation
        LowBalanceFraudCheckWorker.perform_in(5.seconds, id)
      end

      true
    end
  end

  def refund_partial_purchase!(gross_refund_amount_cents, refunding_user_id, processor_refund_id: nil)
    partially_refunded_previously = self.stripe_partially_refunded
    ActiveRecord::Base.transaction do
      if (gross_amount_refunded_cents + gross_refund_amount_cents) >= total_transaction_cents
        self.stripe_partially_refunded = false
        self.stripe_refunded = true
      else
        self.stripe_refunded = false
        self.stripe_partially_refunded = true
      end
      self.is_refund_chargeback_fee_waived = !charged_using_gumroad_merchant_account?
      if partially_refunded_previously && stripe_refunded
        refund = build_partial_full_refund(refunding_user_id:)
      else
        refund = build_refund(gross_refund_amount: gross_refund_amount_cents,
                              refunding_user_id:)
      end

      if refund.present?
        refund.processor_refund_id = processor_refund_id
        refunds << refund
      end
      save!
      Credit.create_for_vat_exclusive_refund!(refund:) if paypal_order_id.present? || merchant_account&.is_a_stripe_connect_account?
      debit_processor_fee_from_merchant_account!(refund) unless is_refund_chargeback_fee_waived
      CustomerMailer.partial_refund(email, link.id, id, gross_refund_amount_cents, formatted_refund_state).deliver_later(queue: "critical")
      true
    end
  end

  def refund_gumroad_taxes!(refunding_user_id:, note: nil, business_vat_id: nil)
    gumroad_tax_refundable_cents = self.gumroad_tax_refundable_cents
    return false if stripe_refunded || gumroad_tax_refundable_cents <= 0

    begin
      logger.info("Refunding purchase: #{id} gumroad taxes: #{self.gumroad_tax_refundable_cents}")
      charge_refund = ChargeProcessor.refund!(charge_processor_id, stripe_transaction_id,
                                              amount_cents: gumroad_tax_refundable_cents,
                                              reverse_transfer: false,
                                              merchant_account:,
                                              paypal_order_purchase_unit_refund: paypal_order_id.present?)
      logger.info("Refunding purchase: #{id} completed with ID: #{charge_refund.id}, Flow of Funds: #{charge_refund.flow_of_funds.to_h}")

      ActiveRecord::Base.transaction do
        refund = Refund.new(total_transaction_cents: gumroad_tax_refundable_cents,
                            amount_cents: 0,
                            creator_tax_cents: 0,
                            fee_cents: 0,
                            gumroad_tax_cents: gumroad_tax_refundable_cents,
                            refunding_user_id:)
        refund.note = note
        refund.business_vat_id = business_vat_id
        refund.processor_refund_id = charge_refund.id
        refunds << refund
        save!
        Credit.create_for_vat_refund!(refund:) if paypal_order_id.present? || merchant_account&.is_a_stripe_connect_account?
      end
      true
    rescue ChargeProcessorAlreadyRefundedError => e
      logger.error "Charge was already refunded in purchase: #{external_id}. Response: #{e.message}"
      false
    rescue ChargeProcessorInvalidRequestError
      false
    rescue ChargeProcessorUnavailableError => e
      logger.error "Error while refunding a charge: #{e.message} in purchase: #{external_id}"
      errors.add :base, "There is a temporary problem. Try to refund later."
      false
    end
  end

  def refund_for_fraud_and_block_buyer!(refunding_user_id)
    refund_for_fraud!(refunding_user_id)
    block_buyer!(blocking_user_id: refunding_user_id)
  end

  def refund_for_fraud!(refunding_user_id)
    refund_and_save!(refunding_user_id, is_for_fraud: true)
    subscription.cancel_effective_immediately! if subscription.present? && !subscription.deactivated?
    ContactingCreatorMailer.purchase_refunded_for_fraud(id).deliver_later(queue: "default") unless seller.suspended?
  end

  def formatted_refund_state
    return "" unless stripe_partially_refunded || stripe_refunded

    stripe_partially_refunded ? "partially" : "fully"
  end

  def within_refund_policy_timeframe?
    return false unless successful? || gift_receiver_purchase_successful? || not_charged?
    return false if refunded? || chargedback?

    refund_policy = purchase_refund_policy
    return false unless refund_policy.present?

    max_days = refund_policy.max_refund_period_in_days
    return false if max_days.nil? || max_days <= 0

    created_at > max_days.days.ago
  end

  private
    def refundable_amounts
      amounts_query = "COALESCE(SUM(total_transaction_cents), 0) AS tt_cents, COALESCE(SUM(amount_cents), 0) AS p_cents, " \
                        "COALESCE(SUM(creator_tax_cents), 0) AS ct_cents, COALESCE(SUM(gumroad_tax_cents), 0) as gt_cents," \
                        "COALESCE(SUM(fee_cents), 0) AS ft_cents"
      existing_refunds = refunds.select(amounts_query).first
      return unless existing_refunds
      { total_transaction_cents: (total_transaction_cents - existing_refunds.tt_cents),
        amount_cents: (price_cents - existing_refunds.p_cents),
        fee_cents: (fee_cents - existing_refunds.ft_cents),
        creator_tax_cents: (tax_cents - existing_refunds.ct_cents),
        gumroad_tax_cents: (gumroad_tax_cents - existing_refunds.gt_cents) }
    end

    def reverse_the_transfer_made_for_dispute_win!
      return unless merchant_account&.holder_of_funds == HolderOfFunds::STRIPE
      return unless dispute&.won_at.present?

      transfers = Stripe::Transfer.list({ destination: merchant_account.charge_processor_merchant_id, created: { gte: dispute.won_at.to_i - 60000 },  limit: 100 })
      transfer = transfers.select { |tr| tr["description"]&.include?("Dispute #{dispute.charge_processor_dispute_id} won") }.first
      Stripe::Transfer.create_reversal(transfer.id, { amount: amount_refundable_cents }) if transfer.present?
    end

    def debit_processor_fee_from_merchant_account!(refund)
      Credit.create_for_refund_fee_retention!(refund:)
    end

    def reverse_excess_amount_from_stripe_transfer(refund:)
      return unless merchant_account&.holder_of_funds == HolderOfFunds::STRIPE
      return unless refund.purchase.gumroad_tax_cents > 0 && refund.purchase.gumroad_tax_cents == refund.purchase.gumroad_tax_refunded_cents

      amount_cents_to_be_reversed_usd = refund.balance_transactions.where(user_id: refund.purchase.seller_id).last.issued_amount_net_cents.abs

      stripe_charge = Stripe::Charge.retrieve(refund.purchase.stripe_transaction_id)
      transfer = Stripe::Transfer.retrieve(id: stripe_charge.transfer)
      amount_cents_already_reversed_usd = transfer.reversals.data.find { |d| d.source_refund == refund.processor_refund_id }.amount.abs

      return unless amount_cents_already_reversed_usd < amount_cents_to_be_reversed_usd

      reversal_amount_cents_usd = amount_cents_to_be_reversed_usd - amount_cents_already_reversed_usd

      transfer_reversal = Stripe::Transfer.create_reversal(transfer.id, { amount: reversal_amount_cents_usd })

      destination_refund = Stripe::Refund.retrieve(transfer_reversal.destination_payment_refund,
                                                   stripe_account: refund.purchase.merchant_account.charge_processor_merchant_id)

      destination_balance_transaction = Stripe::BalanceTransaction.retrieve(destination_refund.balance_transaction,
                                                                            stripe_account: refund.purchase.merchant_account.charge_processor_merchant_id)

      Credit.create_for_partial_refund_transfer_reversal!(amount_cents_usd: -reversal_amount_cents_usd,
                                                          amount_cents_holding_currency: -destination_balance_transaction.net.abs,
                                                          merchant_account: refund.purchase.merchant_account)
    end
end
