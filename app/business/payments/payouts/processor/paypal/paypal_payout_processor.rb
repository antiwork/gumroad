# frozen_string_literal: true

class PaypalPayoutProcessor
  # We would split up the payment into chunks of at most this size, only when necessary, in order to get around the MassPay API limitations.
  # See perform_payment_in_split_mode. This is a hack that should be replaced with a proper split payout mechanism that supports a single Balance being
  # split into separate Payments, since a single day's balance could be larger than the paypal payout limit.
  MAX_SPLIT_PAYMENT_BY_CENTS = 20_000_00 # $20,000 since that's the maximum the MassPay API accepts as per PayPal support
  SPLIT_PAYMENT_TXN_ID = "split payment; see split_payments_info"
  SPLIT_PAYMENT_UNIQUE_ID_PREFIX = "SPLIT_"
  PAYPAL_API_PARAMS = {
    "USER" => PAYPAL_USER,
    "PWD" => PAYPAL_PASS,
    "SIGNATURE" => PAYPAL_SIGNATURE,
    "VERSION" => "90.0",
    "CURRENCYCODE" => "USD"
  }.freeze
  PAYOUT_RECIPIENTS_PER_JOB = 240 # Max recipients allowed in one API call is 250. Using 240 because I don't trust PayPal.
  PAYPAL_PAYOUT_FEE_PERCENT = 2
  PAYPAL_PAYOUT_FEE_EXEMPT_COUNTRY_CODES = [Compliance::Countries::BRA.alpha2, Compliance::Countries::IND.alpha2]

  # Public: Determines if it's possible for this processor to payout
  # the user by checking that the user has provided us with the
  # information we need to be able to payout with this processor.
  #
  # This payout processor can payout any user who has provided a paypal address,
  # but will also opt to not payout users who have previous paypal payouts that were incomplete
  # or if they've provided a bank account because it's possibe for users to have both
  # a payment address and a bank account and we prefer bank payouts.
  def self.is_user_payable(user, amount_payable_usd_cents, add_comment: false, from_admin: false, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    payout_date = Time.current.to_fs(:formatted_date_full_month)

    # Don't allow payout to PayPal if the user has given us a bank account.
    return false if user.active_bank_account

    # PayPal does not support instant payouts.
    return false if payout_type == Payouts::PAYOUT_TYPE_INSTANT

    # Don't allow payout to PayPal if the StripePayoutProcessor can handle it.
    return false if StripePayoutProcessor.is_user_payable(user, amount_payable_usd_cents)

    payout_email = user.paypal_payout_email

    # User is payable on PayPal if they've provided an email address.
    if !EmailFormatValidator.valid?(payout_email)
      user.add_payout_note(content: "Payout via PayPal on #{payout_date} skipped because the account does not have a valid PayPal payment address") if add_comment
      return false
    end

    # Email address contains non-ascii characters
    unless payout_email.ascii_only?
      user.add_payout_note(content: "Payout via PayPal on #{payout_date} skipped because the PayPal payment address contains invalid characters") if add_comment
      return false
    end

    # User hasn't given us their compliance info.
    if user.alive_user_compliance_info.try(:legal_entity_name).blank? && !user.has_paypal_account_connected?
      user.add_payout_note(content: "Payout via PayPal on #{payout_date} skipped because the account does not have a valid name on record") if add_comment
      return false
    end

    # If a user's previous payment is still processing, don't allow for new payments.
    processing_payment_ids = user.payments.processing.ids
    if processing_payment_ids.any?
      user.add_payout_note(content: "Payout via PayPal on #{payout_date} skipped because there are already payouts (ID #{processing_payment_ids.join(', ')}) in processing") if add_comment
      return false
    end

    true
  end

  def self.has_valid_payout_info?(user)
    payout_email = user.paypal_payout_email

    # User is payable on PayPal if they've provided an email address.
    return false unless EmailFormatValidator.valid?(payout_email)
    # Email address contains non-ascii characters
    return false unless payout_email.ascii_only?
    # User hasn't given us their compliance info.
    return false if user.alive_user_compliance_info.try(:legal_entity_name).blank? && user.paypal_connect_account.blank?

    true
  end

  # Public: Determines if the processor can payout the balance. Since
  # balances can be being held either by Gumroad or by specific processors
  # a balance may not be payable by a processor if the balance is not
  # being held by Gumroad.
  #
  # This payout processor can payout any balance that's held by Gumroad,
  # where the creator was a supplier and Gumroad was the merchant.
  def self.is_balance_payable(balance)
    balance.merchant_account.holder_of_funds == HolderOfFunds::GUMROAD && balance.holding_currency == Currency::USD
  end

  # Public: Takes the actions required to prepare the payment, that include:
  #   * Setting the currency.
  #   * Setting the amount_cents.
  # Returns an array of errors.
  def self.prepare_payment_and_set_amount(payment, balances)
    payment.currency = Currency::USD
    payment.amount_cents = balances.sum(&:holding_amount_cents)
    if payment.user.charge_paypal_payout_fee?
      payment.gumroad_fee_cents = (payment.amount_cents * PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      payment.amount_cents -= payment.gumroad_fee_cents
    end
    []
  end

  def self.enqueue_payments(user_ids, date_string)
    user_ids.each_slice(PAYOUT_RECIPIENTS_PER_JOB).with_index do |ids, index|
      # Work around (unknown) rate-limits by introducing a delay
      PayoutUsersWorker.perform_in(index.minutes, date_string, PayoutProcessorType::PAYPAL, ids)
    end
  end

  def self.process_payments(payments)
    regular_payments = []
    split_mode_payments = []

    payments.each do |payment|
      user = payment.user

      if user.should_paypal_payout_be_split? && payment.amount_cents > split_payment_by_cents(user)
        split_mode_payments << payment
      else
        regular_payments << payment
      end
    end

    split_mode_payments.each do |payment|
      perform_split_payment(payment)
    rescue => e
      Rails.logger.error "Error processing payment #{payment.id} => #{e.class.name}: #{e.message}"
      Rails.logger.error "Error processing payment #{payment.id} => #{e.backtrace.join("\n")}"
      Bugsnag.notify(e)
      next
    end

    perform_payments(regular_payments) if regular_payments.present?
  end

  def self.perform_payments(payments)
    mass_pay_params = paypal_auth_params
    payment_index = 0
    user_ids = []

    payments.each do |payment|
      mass_pay_params["L_EMAIL#{payment_index}"] = payment.payment_address
      mass_pay_params["L_AMT#{payment_index}"] = payment.amount_cents / 100.0
      mass_pay_params["L_UNIQUEID#{payment_index}"] = payment.id
      mass_pay_params["L_NOTE#{payment_index}"] = note_for_paypal_payment(payment)

      user_ids << payment.user_id

      payment_index += 1
    end

    Rails.logger.info("Paypal payouts: posting #{mass_pay_params} to #{PAYPAL_ENDPOINT} for user IDs #{user_ids}")
    paypal_response = HTTParty.post(PAYPAL_ENDPOINT, body: mass_pay_params)
    Rails.logger.info("Paypal payouts: received #{paypal_response} from #{PAYPAL_ENDPOINT} for user IDs #{user_ids}")

    parsed_paypal_response = Rack::Utils.parse_nested_query(paypal_response)
    ack_status = parsed_paypal_response["ACK"]
    transaction_succeeded = %w[Success SuccessWithWarning].include?(ack_status)
    correlation_id = parsed_paypal_response["CORRELATIONID"]

    payments.each { |payment| payment.update(correlation_id:) }
    payments.each(&:mark_failed!) unless transaction_succeeded

    errors = errors_for_parsed_paypal_response(parsed_paypal_response) if ack_status != "Success"
    Rails.logger.info("Paypal Payouts: Payout errors for user IDs #{user_ids}: #{errors.inspect}") if errors.present?
  end

  # Public: Sends the money in `split_payment_by_cents(payment.user)` increments.
  def self.perform_split_payment(payment)
    payment.was_created_in_split_mode = true
    split_payment_cents = split_payment_by_cents(payment.user)

    errors = []

    number_of_split_payouts = (payment.amount_cents.to_f / split_payment_cents).ceil
    paid_so_far_amount_cents = 0
    (1..number_of_split_payouts).each do |payout_number|
      remaining_amount_cents = payment.amount_cents - paid_so_far_amount_cents
      split_payment_amount_cents = [remaining_amount_cents, split_payment_cents].min

      params = paypal_auth_params
      split_payment_unique_id = "#{SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-#{payout_number}" # According to paypal this field has a 30 byte limit.
      params["L_EMAIL0"] = payment.payment_address
      params["L_AMT0"] = split_payment_amount_cents / 100.0
      params["L_UNIQUEID0"] = split_payment_unique_id
      params["L_NOTE0"] = note_for_paypal_payment(payment)

      Rails.logger.info("Paypal payouts: posting #{params} to #{PAYPAL_ENDPOINT} for user ID #{payment.user.id}")
      paypal_response = HTTParty.post(PAYPAL_ENDPOINT, body: params)
      Rails.logger.info("Paypal payouts: received #{paypal_response} from #{PAYPAL_ENDPOINT} for user ID #{payment.user.id}")
      paid_so_far_amount_cents += split_payment_amount_cents

      parsed_paypal_response = Rack::Utils.parse_nested_query(paypal_response)
      ack_status = parsed_paypal_response["ACK"]
      transaction_succeeded = %w[Success SuccessWithWarning].include?(ack_status)
      correlation_id = parsed_paypal_response["CORRELATIONID"]
      errors << errors_for_parsed_paypal_response(parsed_paypal_response) if ack_status != "Success"
      split_payment_info = {
        state: transaction_succeeded ? "processing" : "failed",
        correlation_id:,
        amount_cents: split_payment_amount_cents,
        errors:
      }
      payment.split_payments_info.nil? ? payment.split_payments_info = [split_payment_info] : payment.split_payments_info << split_payment_info
      payment.correlation_id = correlation_id
      payment.save!

      # Mark it as failed and stop the payments only if the first transaction failed.
      payment.mark_failed! && break if !transaction_succeeded && payout_number == 1
    end

    Rails.logger.info("Payouts: Split mode payout of #{payment.amount_cents} attempted for user with id: #{payment.user_id}")
    Rails.logger.info("Payouts: Split mode payout errors for user with id: #{payment.user_id} #{errors.inspect}") if errors.present?
  end

  def self.handle_paypal_event(paypal_event)
    Rails.logger.info("Paypal payouts: received IPN #{paypal_event}")
    # https://developer.paypal.com/docs/api-basics/notifications/ipn/IPNandPDTVariables/#payment-information-variables

    payments_data = []
    paypal_event.each_pair do |k, v|
      next unless k =~ /.*_(\d+)$/

      payments_data[Regexp.last_match[1].to_i] ||= {}
      payments_data[Regexp.last_match[1].to_i][k.gsub(/_\d+$/, "")] = v
    end
    payments_data.compact!
    payments_data.each do |payment_information|
      payment_unique_id = payment_information["unique_id"].to_s
      if payment_unique_id.start_with?(SPLIT_PAYMENT_UNIQUE_ID_PREFIX)
        handle_paypal_event_for_split_payment(payment_unique_id, payment_information)
      else
        handle_paypal_event_for_non_split_payment(payment_unique_id, payment_information)
      end
    end
  end

  def self.split_payment_by_cents(user)
    cents = user.split_payment_by_cents
    if cents.present? && cents <= MAX_SPLIT_PAYMENT_BY_CENTS
      cents
    else
      MAX_SPLIT_PAYMENT_BY_CENTS
    end
  end

  # TODO: Make methods from this point onwards private

  def self.paypal_auth_params
    PAYPAL_API_PARAMS.merge("METHOD" => "MassPay", "RECEIVERTYPE" => "EmailAddress")
  end

  def self.errors_for_parsed_paypal_response(parsed_paypal_response)
    errors = []
    error_index = 0
    while parsed_paypal_response["L_SHORTMESSAGE#{error_index}"].present?
      error_code = parsed_paypal_response["L_ERRORCODE#{error_index}"]
      short_message = parsed_paypal_response["L_SHORTMESSAGE#{error_index}"]
      long_message = parsed_paypal_response["L_LONGMESSAGE#{error_index}"]
      errors << "#{error_code} - #{short_message} - #{long_message}"
      error_index += 1
    end
    errors
  end

  def self.handle_paypal_event_for_non_split_payment(payment_unique_id, paypal_event)
    payment = Payment.find_by(id: payment_unique_id)
    if payment.nil?
      Rails.logger.warn "Paypal payouts: unique_id #{payment_unique_id} didn't correspond to a payment ID"
      return
    end

    return unless Payment::NON_TERMINAL_STATES.include?(payment.state)

    payment.with_lock do
      payment.txn_id = paypal_event["masspay_txn_id"]
      payment.processor_fee_cents = 100 * paypal_event["mc_fee"].to_f if paypal_event["mc_fee"]
      payment.save!
      new_payment_state = paypal_event["status"].try(:downcase)
      # Paypal is sending incorrect payment status ('Pending') in the IPN callback for some of the payments where the
      # actual status is either 'Unclaimed' or 'Completed'. Until the issue is resolved at Paypal, we get the actual
      # status using another API call to Paypal.
      # Ref: https://github.com/gumroad/web/issues/9474
      if new_payment_state == "pending"
        new_payment_state = get_latest_payment_state_from_paypal(payment.amount_cents,
                                                                 payment.txn_id,
                                                                 payment.created_at.beginning_of_day - 1.day,
                                                                 new_payment_state)
      end
      if new_payment_state == "pending"
        UpdatePayoutStatusWorker.perform_in(5.minutes, payment.id)
      elsif payment.state != new_payment_state
        if new_payment_state == "failed"
          failure_reason = "PAYPAL #{paypal_event["reason_code"]}" if paypal_event["reason_code"].present?
          payment.mark_failed!(failure_reason)
        else
          payment.mark!(new_payment_state)
        end
      end
    end
  end

  def self.handle_paypal_event_for_split_payment(payment_unique_id, paypal_event)
    payment_id_and_split_payment_number = payment_unique_id.split(SPLIT_PAYMENT_UNIQUE_ID_PREFIX)[1]
    payment_id, split_payment_number = payment_id_and_split_payment_number.split("-").map(&:to_i)
    payment = Payment.find_by(id: payment_id)
    if payment.nil?
      Rails.logger.warn "Paypal payouts: unique_id #{payment_unique_id} didn't correspond to a payment ID"
      return
    end

    payment.with_lock do
      split_payment_index = split_payment_number - 1 # split_payment_number is 1-based.
      split_payment_info = payment.split_payments_info[split_payment_index]
      return unless %w[processing pending].include?(split_payment_info["state"])

      split_payment_info["txn_id"] = paypal_event["masspay_txn_id"]
      split_payment_info["state"] = paypal_event["status"].try(:downcase)
      payment.processor_fee_cents += 100 * paypal_event["mc_fee"].to_f if paypal_event["mc_fee"]
      payment.save!

      # Paypal is sending incorrect payment status ('Pending') in the IPN callback for some of the payments where the
      # actual status is either 'Unclaimed' or 'Completed'. Until the issue is resolved at Paypal, we get the actual
      # status using another API call to Paypal.
      # Ref: https://github.com/gumroad/web/issues/9474
      UpdatePayoutStatusWorker.perform_in(5.minutes, payment.id) if split_payment_info["state"] == "pending"

      update_split_payment_state(payment)
    end
  end

  def self.update_split_payment_state(payment)
    split_payment_states = payment.split_payments_info.map { |payment_info| payment_info["state"] }

    all_split_payments_completed = split_payment_states.all? { |state| state == "completed" }
    all_split_payments_failed = split_payment_states.all? { |state| state == "failed" }
    no_split_payments_are_processing = split_payment_states.none? { |state| %w[processing pending].include?(state) }

    if all_split_payments_completed
      payment.txn_id = SPLIT_PAYMENT_TXN_ID
      payment.mark_completed!
    elsif all_split_payments_failed
      payment.mark_failed!
    elsif no_split_payments_are_processing
      # This means that no split payments are in the processing state. It also means that some of them have failed and some have succeeded.
      Bugsnag.notify("Payment id #{payment.id} was split and some of the split payments failed and some succeeded")
    end
  end

  def self.get_latest_payment_state_from_paypal(amount_cents, transaction_id, start_date, current_state)
    params = PAYPAL_API_PARAMS.merge("METHOD" => "TransactionSearch", "TRANSACTIONCLASS" => "Sent")
    amt_str = format("%.2f", (amount_cents / 100.0).to_s)
    paypal_response = HTTParty.post(PAYPAL_ENDPOINT, body: params.merge("AMT" => amt_str,
                                                                        "TRANSACTIONID" => transaction_id,
                                                                        "STARTDATE" => start_date.iso8601))
    response = Rack::Utils.parse_nested_query(paypal_response.parsed_response)
    # Discard if the data we need is missing, or there is more than one search result, or the status is anything other than 'Unclaimed' or 'Completed'.
    if response["L_STATUS0"].blank? || response["L_AMT0"].blank? || response["L_TRANSACTIONID0"].blank? || response["L_FEEAMT0"].blank? ||
       response["L_TIMESTAMP1"].present? ||
       %w[unclaimed completed].exclude?(response["L_STATUS0"].downcase)
      current_state
    else
      response["L_STATUS0"].downcase
    end
  end

  def self.search_payment_on_paypal(amount_cents:, transaction_id: nil, payment_address: nil, start_date:, end_date: nil)
    return if transaction_id.blank? && payment_address.blank?

    params = PAYPAL_API_PARAMS.merge("METHOD" => "TransactionSearch", "TRANSACTIONCLASS" => "Sent")
    amt_str = format("%.2f", (amount_cents / 100.0).to_s)

    paypal_response = if transaction_id.present?
      HTTParty.post(PAYPAL_ENDPOINT, body: params.merge("TRANSACTIONID" => transaction_id,
                                                        "STARTDATE" => start_date.iso8601))
    else
      HTTParty.post(PAYPAL_ENDPOINT, body: params.merge("AMT" => amt_str,
                                                        "EMAIL" => payment_address,
                                                        "STARTDATE" => start_date.iso8601,
                                                        "ENDDATE" => end_date.iso8601))
    end

    response = Rack::Utils.parse_nested_query(paypal_response.parsed_response)

    if response["L_STATUS0"].present? && response["L_STATUS1"].present? && response["L_STATUS2"].blank? &&
      transaction_id.in?([response["L_TRANSACTIONID0"], response["L_TRANSACTIONID1"]]) &&
      Set.new([response["L_AMT0"], response["L_AMT1"]]) == Set.new([amt_str, "-#{amt_str}"])
      # If the transaction is reversed or returned or cancelled, PayPal returns both the original transaction
      # and the reversed/returned/cancelled transaction, when searched with the original transaction ID.
      # In that case, return proper reversed/returned/cancelled state.
      if Set.new([response["L_STATUS0"].downcase, response["L_STATUS1"].downcase]) == Set.new([Payment::COMPLETED, Payment::REVERSED])
        { state: Payment::REVERSED, transaction_id: response["L_TRANSACTIONID0"], correlation_id: response["CORRELATIONID"], paypal_fee: response["L_FEEAMT0"] }
      elsif Set.new([response["L_STATUS0"].downcase, response["L_STATUS1"].downcase]) == Set.new([Payment::COMPLETED, "canceled"])
        { state: Payment::CANCELLED, transaction_id: response["L_TRANSACTIONID0"], correlation_id: response["CORRELATIONID"], paypal_fee: response["L_FEEAMT0"] }
      elsif Set.new([response["L_STATUS0"].downcase, response["L_STATUS1"].downcase]) == Set.new([Payment::COMPLETED, Payment::RETURNED])
        { state: Payment::RETURNED, transaction_id: response["L_TRANSACTIONID0"], correlation_id: response["CORRELATIONID"], paypal_fee: response["L_FEEAMT0"] }
      else
        # If two transactions are returned and they are not original and reversed/returned/canceled, raise an error as this shouldn't happen.
        raise "Multiple PayPal transactions found for #{payment_address} with amount #{amt_str} between #{start_date} and #{end_date}"
      end
    elsif response["L_STATUS0"].present? && response["L_STATUS1"].present?
      # If multiple transactions are returned and they are not original and reversed/returned/canceled, raise an error as this shouldn't happen.
      raise "Multiple PayPal transactions found for #{payment_address} with amount #{amt_str} between #{start_date} and #{end_date}"
    elsif response["L_STATUS0"].present?
      # If only one transaction is returned, return that transaction's current state.
      { state: response["L_STATUS0"].downcase, transaction_id: response["L_TRANSACTIONID0"], correlation_id: response["CORRELATIONID"], paypal_fee: response["L_FEEAMT0"] }
    else
      # If we did not have a transaction ID and searched using payment address,
      # it's possible that the transaction was never made on PayPal.
      return if transaction_id.blank?
      # But if we had a transaction ID we should find a corresponding transaction on PayPal,
      # raise an error if that's not the case.
      raise "No PayPal transaction found for transaction ID #{transaction_id} and amount #{amt_str}"
    end
  end

  def self.note_for_paypal_payment(payment)
    user              = payment.user
    legal_entity_name = user.alive_user_compliance_info&.legal_entity_name.presence || user.name_or_username

    "#{legal_entity_name}, selling digital products / memberships"
  end

  def self.current_paypal_balance_cents
    paypal_response = HTTParty.post(PAYPAL_ENDPOINT, body: PAYPAL_API_PARAMS.merge("METHOD" => "GetBalance"))
    response = Rack::Utils.parse_nested_query(paypal_response.parsed_response)
    (response["L_AMT0"].to_d * 100).to_i
  end

  # This method assumes that each topup is made for $100,000.
  # We've always made topups in chunks of $100,000 so far.
  # If that ever changes, this method will need to be updated accordingly.
  # The bank account transfer transactions are not searchable by type,
  # so using the $100,000 amount to easily search for them here.
  def self.topup_amount_in_transit
    individual_topup_amount = 100000

    params = PAYPAL_API_PARAMS.merge("METHOD" => "TransactionSearch",
                                     "AMT" => individual_topup_amount.to_s,
                                     "STARTDATE" => 2.weeks.ago.iso8601) # Topups older than 2 weeks should have already completed
    paypal_response = HTTParty.post(PAYPAL_ENDPOINT, body: params)
    response = Rack::Utils.parse_nested_query(paypal_response.parsed_response)
    return 0 unless %w[Success SuccessWithWarning].include?(response["ACK"])

    topup_amount = 0

    number_of_topups_made = response.keys.select { _1.include?("L_TRANSACTIONID") }.count
    number_of_topups_made.times do |i|
      topup_amount += individual_topup_amount if response["L_TYPE#{i}"] == "Transfer" &&
        response["L_NAME#{i}"] == "Bank Account" &&
        response["L_STATUS#{i}"] == "Uncleared" &&
        response["L_AMT#{i}"].to_i == individual_topup_amount
    end

    topup_amount
  end
end
