# frozen_string_literal: true

# Live runs write seller balances. Dry-run each batch first.
class Onetime::ApplySourcelessCapitalDeductions
  CREDIT_IDS = [
    483839, 483840, 483843, 483928, 483933, 483996, 484035, 484037, 484410, 484746, 484830, 486071,
    486072, 486073, 486074, 486075, 486076, 486077, 486078, 486079, 486080, 486081, 486082, 486083,
    486084, 486085, 486632, 487478, 488046, 488073, 488413, 489353, 491912, 493097, 494007, 495303,
    496964, 498064, 498065, 499871, 500817, 500818, 500819, 502129, 502190, 503403, 503501, 503502,
    506133, 506134, 508689, 508690, 508691, 508734, 510258, 511112, 511222, 511234, 511305, 511870,
    512359, 512536, 513462, 513724, 513735, 514847, 515269, 515629, 515630, 515632, 515633, 515634,
    515636, 515640, 515646, 515661, 515685, 515708, 516647, 517041, 517042, 517043, 517044, 517045,
    517046, 517049, 517052, 517060, 517070, 517093, 517323, 517457, 517856, 519308, 519971, 520207,
    521262, 522041, 522101, 522546, 522547, 522548, 522549, 522550, 522552, 522555, 522557, 522562,
    522571, 522588, 523629, 524504, 524506, 524554, 527394, 527395, 527396, 527398, 528287, 528845,
    529225, 530240, 530241, 530242, 530243, 531115, 532870, 532871, 532872, 535840, 535841, 535842,
    536615, 536617, 538789, 538950, 538951, 538954, 541834, 541835, 541836, 541837, 542122, 545632,
    546300, 546557, 548814, 548850, 548851, 550851, 550853, 550983, 550984, 551767, 552764, 552767,
    552768, 552842, 552855, 552856, 553184, 554471, 554935, 554967, 555496, 556559, 558105, 559362,
    560173, 560174, 561646, 562678, 562679, 562680, 564854, 565315, 567467, 567468, 567469, 567470,
    569535, 569551, 569552, 569553, 570172, 570959, 571147, 571177, 571400, 571753, 571764, 572883,
    574044, 574045, 574279, 575181, 576209, 578300, 578596, 580121, 580355, 580356, 580778, 581299,
    582474, 582739, 584481, 584482, 584484, 584485, 586472, 587808, 588361, 588362, 588363, 588833,
    590284, 590371, 590519, 591099, 593143, 593936, 593937, 593938, 595657, 596699, 596700, 597290,
    597291, 597292, 599067, 599068, 599069, 600379, 600802, 600803, 600804, 602944, 602945, 603770,
    603818, 604073, 604720, 605656, 605816, 606781, 608024, 608627, 608628, 609218, 609433, 610191,
    610491, 610492, 610576, 610654, 611208, 612149, 612151, 612395, 612612, 612613, 612973, 613144,
    613976, 614025, 614564, 614654, 615545, 615942, 617000, 617370, 617951, 618110, 618929, 619089,
    619140, 619438, 620535, 621190, 621191, 621879, 622715, 622739, 623227, 623974, 625238, 625415,
    625416, 625418, 625419, 625420, 625433, 625435, 625439, 625451, 625475, 625498, 625734, 626277,
    627166, 627167, 627644, 629263, 629547, 630060, 630765, 631412, 631439, 631549, 631635, 631636,
    631955, 632974, 632975, 634453, 634454, 636234, 636235, 636433, 636686, 636925, 638489, 638490,
    640056, 643863, 643864, 643865, 643992, 644715, 645338, 645345, 645648, 648210, 648211, 648886,
    651661, 653594, 654312, 654823, 654824, 657134, 658495, 661957, 664040, 665048, 665101, 665315,
    665316, 666449, 666605, 669318, 669671, 671062, 672886
  ].freeze

  # skip_negative leaves a credit alone when applying it would end the seller's unpaid ledger, or the credit's own
  # merchant account and currency group, below zero. A negative ledger or group holds the seller's payouts, so the
  # caller decides whether that is acceptable.
  def initialize(credit_ids: CREDIT_IDS, dry_run: true, skip_negative: false)
    raise ArgumentError, "Only listed credits can be applied" unless (credit_ids - CREDIT_IDS).empty?
    raise ArgumentError, "Credit IDs must be unique" unless credit_ids.uniq.size == credit_ids.size

    @credit_ids = credit_ids
    @dry_run = dry_run
    @skip_negative = skip_negative
  end

  def process
    # A dry run applies nothing, so later credits of the batch see earlier ones through these.
    @projected_deltas = Hash.new(0)
    @projected_groups = Hash.new(0)
    @projected_dates = {}
    @credit_ids.map do |credit_id|
      process_credit(credit_id)
    rescue => e
      { status: :refused, credit_id:, error: e.message }
    end
  end

  private
    def process_credit(credit_id)
      credit = Credit.find(credit_id)
      return already_applied(credit) if credit.balance_id.present?

      # Stripe is read before taking the lock; the ledger checks are repeated under it.
      verify_record!(credit)
      stripe = verify_stripe_source_is_absent!(credit)

      # Payouts claims balances under the seller lock, so holding it keeps the ledger judged by skip_negative
      # unchanged until the deduction lands. It is taken before the Credit lock, never after.
      return apply_credit(credit, stripe) unless @skip_negative && !@dry_run

      ApplicationRecord.connected_to(role: :writing) { credit.user.with_lock { apply_credit(credit, stripe) } }
    end

    def apply_credit(credit, stripe)
      ApplicationRecord.connected_to(role: :writing) do
        credit.with_lock do
          return already_applied(credit) if credit.balance_id.present?

          verify_record!(credit)
          verify_stripe_fields!(credit, stripe)
          transaction = credit.balance_transaction
          verify_balance_transaction!(credit, transaction) if transaction
          projection = project(credit, transaction)
          return skipped(credit, projection) if @skip_negative && projection[:new_deduction] && projection[:ends_negative]
          return dry_run_result(credit, transaction, stripe, projection) if @dry_run

          unless unlinked?(credit)
            credit.update!(financing_paydown_purchase: nil, stripe_loan_paydown_reason: Credit::AUTOMATIC_CAPITAL_WITHHOLDING,
                           stripe_loan_paydown_currency: Currency::USD, **stripe)
          end
        end
      end

      # This locks a Balance and creates the missing BalanceTransaction. Under skip_negative the seller lock, and so the
      # Credit lock, is still held and a failure rolls back the unlink too; the order stays seller, credit, balance.
      credit.apply_financing_paydown!(merchant_account: credit.merchant_account, amount_cents: credit.amount_cents,
                                      currency: Currency::USD, reason: Credit::AUTOMATIC_CAPITAL_WITHHOLDING,
                                      financing_paydown_purchase_id: nil)
      credit.reload
      result = { status: :applied, credit_id: credit.id, balance_transaction_id: credit.balance_transaction.id,
                 balance_id: credit.balance_id, deduction_cents: credit.amount_cents }
      Rails.logger.info("[ApplySourcelessCapitalDeductions] #{result.to_json}")
      result
    end

    # An interrupted earlier run can leave the purchase already cleared; that state resumes.
    def unlinked?(credit)
      credit.financing_paydown_purchase_id.nil? && credit.stripe_loan_paydown_reason == Credit::AUTOMATIC_CAPITAL_WITHHOLDING
    end

    def verify_record!(credit)
      merchant_account = credit.merchant_account
      raise "Credit is not a Capital deduction" unless credit.stripe_loan_paydown_id.present? && credit.amount_cents.negative?
      unless merchant_account.user_id == credit.user_id && merchant_account.charge_processor_id == StripeChargeProcessor.charge_processor_id &&
             merchant_account.holder_of_funds == HolderOfFunds::STRIPE && merchant_account.currency == Currency::USD &&
             credit.stripe_loan_paydown_currency.in?([nil, Currency::USD])
        raise "Merchant account is not a USD Stripe account of the seller"
      end
      unless unlinked?(credit)
        purchase = credit.financing_paydown_purchase
        unless purchase && purchase.seller_id == credit.user_id && purchase.succeeded_at.nil? && purchase.stripe_transaction_id.blank?
          raise "Credit is not linked to a never-charged purchase"
        end
      end
      unless credit.user.credits.where("json_data->'$.stripe_loan_paydown_id' = ?", credit.stripe_loan_paydown_id).count == 1 &&
             BalanceTransaction.where(credit_id: credit.id).count <= 1
        raise "Capital deduction has duplicate records"
      end
    end

    def verify_stripe_source_is_absent!(credit)
      account = credit.merchant_account.charge_processor_merchant_id
      # Stripe Ruby 12.5.0 does not wrap Capital financing transactions.
      response = Stripe.raw_request(:get, "/v1/capital/financing_transactions/#{credit.stripe_loan_paydown_id}", {}, { stripe_account: account })
      financing = JSON.parse(response.http_body)
      details = financing["details"] || {}
      unless financing["account"] == account && financing["type"] == "payment" &&
             details["reason"] == Credit::AUTOMATIC_CAPITAL_WITHHOLDING && details["currency"] == Currency::USD &&
             details["total_amount"].is_a?(Integer) && -details["total_amount"] == credit.amount_cents &&
             financing["created_at"].is_a?(Integer) && financing["created_at"].positive?
        raise "Stripe financing transaction does not match the credit"
      end

      linked_payment_id = (details["transaction"] || {})["charge"].presence || details["linked_payment"].presence
      raise "Stripe financing transaction has no linked payment" if linked_payment_id.nil?
      linked_transfer_id = Stripe::Charge.retrieve(linked_payment_id, { stripe_account: account }).source_transfer.presence
      raise "Linked payment has no source transfer" if linked_transfer_id.nil?
      transfer = Stripe::Transfer.retrieve(linked_transfer_id)
      raise "Source transfer goes to another account" unless transfer.destination == account
      raise "Source transfer names a charge" if transfer.source_transaction.present?

      { stripe_loan_paydown_deducted_at: financing["created_at"], stripe_loan_paydown_linked_payment_id: linked_payment_id,
        stripe_loan_paydown_linked_transfer_id: linked_transfer_id }
    end

    # A stored value must never be overwritten with a different one. A credit that an interrupted run cleared
    # must carry every field; an untouched one may have none.
    def verify_stripe_fields!(credit, stripe)
      stripe.each do |field, value|
        stored = credit.public_send(field)
        next if stored.nil? && !unlinked?(credit)
        raise "Stored #{field} does not match Stripe" unless stored == value
      end
    end

    def verify_balance_transaction!(credit, transaction)
      unless [transaction.user_id, transaction.merchant_account_id] == [credit.user_id, credit.merchant_account_id] &&
             (transaction.balance_id.nil? || applied_to_credit_balance?(credit, transaction.balance)) &&
             [transaction.purchase_id, transaction.refund_id, transaction.dispute_id].all?(&:nil?) &&
             [transaction.issued_amount_currency, transaction.holding_amount_currency].all?(Currency::USD) &&
             [transaction.issued_amount_gross_cents, transaction.issued_amount_net_cents,
              transaction.holding_amount_gross_cents, transaction.holding_amount_net_cents].all?(credit.amount_cents)
        raise "Balance transaction does not match the credit"
      end
    end

    # A transaction applied by an interrupted run only needs its credit linked; its balance already holds the deduction.
    def applied_to_credit_balance?(credit, balance)
      balance.present? && [balance.user_id, balance.merchant_account_id] == [credit.user_id, credit.merchant_account_id] &&
        [balance.currency, balance.holding_currency].all?(Currency::USD)
    end

    # The balance BalanceTransaction#find_or_create_balance would pick. A missing one is created by the live run, so it starts at 0.
    # Amounts are cumulative over the batch in a dry run, so they match what a live run of the same batch would produce.
    def project(credit, transaction)
      applied_balance = transaction&.balance
      balance = applied_balance || Balance.where(user_id: credit.user_id, merchant_account_id: credit.merchant_account_id,
                                                 currency: Currency::USD, holding_currency: Currency::USD, state: "unpaid").order(date: :asc).first
      balance_key = balance&.id || [:new, credit.user_id, credit.merchant_account_id]
      # An applied transaction is already in held_cents, so only earlier credits of the batch can still move its balance.
      held_cents = (balance&.holding_amount_cents || 0) + @projected_deltas[balance_key]
      if applied_balance
        before_cents, after_cents, ledger_change = held_cents - credit.amount_cents, held_cents, 0
      else
        before_cents, after_cents, ledger_change = held_cents, held_cents + credit.amount_cents, credit.amount_cents
      end
      groups = projected_groups(credit, ledger_change)
      ledger_after_cents = groups.values.sum
      own_group_negative = groups[[credit.merchant_account_id, Currency::USD]].negative?
      { balance:, balance_key:, before_cents:, after_cents:, ledger_change:, ledger_after_cents:,
        ends_negative: ledger_after_cents.negative? || own_group_negative,
        payout_held: ledger_after_cents <= 0 || groups.values.any?(&:negative?), new_deduction: applied_balance.nil? }
    end

    # What Payouts weighs when it decides whether a negative ledger holds a seller's payout: the whole
    # unpaid ledger, and each merchant account and currency group on its own. Payouts also merges Gumroad-held
    # balances into the payout account's group; this does not, so it can flag a group Payouts would not hold.
    def projected_groups(credit, ledger_change)
      groups = Hash.new(0)
      ApplicationRecord.connected_to(role: :writing) do
        Balance.where(user_id: credit.user_id, state: "unpaid").group(:merchant_account_id, :holding_currency).sum(:amount_cents)
      end.each { |group, cents| groups[group] += cents }
      @projected_groups.each { |(user_id, *group), cents| groups[group] += cents if user_id == credit.user_id }
      groups[[credit.merchant_account_id, Currency::USD]] += ledger_change
      groups
    end

    def dry_run_result(credit, transaction, stripe, projection)
      @projected_deltas[projection[:balance_key]] += credit.amount_cents if projection[:new_deduction]
      @projected_groups[[credit.user_id, credit.merchant_account_id, Currency::USD]] += projection[:ledger_change]
      balance = projection[:balance]
      # A live batch opens one balance and reuses it, so later rows name the first credit's date.
      new_balance_date = balance ? nil : (@projected_dates[projection[:balance_key]] ||= Time.zone.at(stripe[:stripe_loan_paydown_deducted_at]).to_date)
      { status: :dry_run, credit_id: credit.id, user_id: credit.user_id, balance_transaction_id: transaction&.id,
        creates_balance_transaction: transaction.nil?, links_applied_transaction: !projection[:new_deduction],
        unlinks_purchase_id: credit.financing_paydown_purchase_id, balance_id: balance&.id, balance_state: balance&.state,
        new_balance_date:,
        before_cents: projection[:before_cents], deduction_cents: credit.amount_cents, after_cents: projection[:after_cents],
        ledger_after_cents: projection[:ledger_after_cents], ends_negative: projection[:ends_negative],
        payout_held: projection[:payout_held] }
    end

    def skipped(credit, projection)
      { status: :skipped, credit_id: credit.id, user_id: credit.user_id, reason: "Ledger would go negative",
        deduction_cents: credit.amount_cents, ledger_after_cents: projection[:ledger_after_cents] }
    end

    def already_applied(credit)
      { status: :already_applied, credit_id: credit.id, balance_id: credit.balance_id }
    end
end
