# frozen_string_literal: true

# Applies automatic Capital withholdings whose Stripe transfer has no source charge. Before the
# forward fix, a blank source matched a seller purchase with no charge id, so the apply step refused
# these credits and they never reached a balance. Each one is re-checked against Stripe, unlinked from
# that purchase and applied the way a new account-level withholding is (earliest unpaid balance).
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

  def initialize(credit_ids: CREDIT_IDS, dry_run: true)
    raise ArgumentError, "Only listed credits can be applied" unless (credit_ids - CREDIT_IDS).empty?

    @credit_ids = credit_ids
    @dry_run = dry_run
  end

  def process
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

      ApplicationRecord.connected_to(role: :writing) do
        credit.with_lock do
          return already_applied(credit) if credit.balance_id.present?

          verify_record!(credit)
          verify_stripe_fields!(credit, stripe) if unlinked?(credit)
          transaction = credit.balance_transaction
          verify_balance_transaction!(credit, transaction) if transaction
          return dry_run_result(credit, transaction, stripe) if @dry_run

          unless unlinked?(credit)
            credit.update!(financing_paydown_purchase: nil, stripe_loan_paydown_reason: Credit::AUTOMATIC_CAPITAL_WITHHOLDING,
                           stripe_loan_paydown_currency: Currency::USD, **stripe)
          end
        end
      end

      # Outside the Credit lock: this locks a Balance and creates the missing BalanceTransaction.
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

    def verify_stripe_fields!(credit, stripe)
      raise "Cleared credit does not match Stripe" unless stripe.all? { |field, value| credit.public_send(field) == value }
    end

    def verify_balance_transaction!(credit, transaction)
      unless [transaction.user_id, transaction.merchant_account_id] == [credit.user_id, credit.merchant_account_id] &&
             transaction.balance_id.nil? && [transaction.purchase_id, transaction.refund_id, transaction.dispute_id].all?(&:nil?) &&
             [transaction.issued_amount_currency, transaction.holding_amount_currency].all?(Currency::USD) &&
             [transaction.issued_amount_gross_cents, transaction.issued_amount_net_cents,
              transaction.holding_amount_gross_cents, transaction.holding_amount_net_cents].all?(credit.amount_cents)
        raise "Balance transaction does not match the credit"
      end
    end

    # The balance BalanceTransaction#find_or_create_balance would pick; a missing one is reported, not created.
    def dry_run_result(credit, transaction, stripe)
      balance = Balance.where(user_id: credit.user_id, merchant_account_id: credit.merchant_account_id, currency: Currency::USD,
                              holding_currency: Currency::USD, state: "unpaid").order(date: :asc).first
      { status: :dry_run, credit_id: credit.id, user_id: credit.user_id, balance_transaction_id: transaction&.id,
        creates_balance_transaction: transaction.nil?, unlinks_purchase_id: credit.financing_paydown_purchase_id,
        balance_id: balance&.id, new_balance_date: balance ? nil : Time.zone.at(stripe[:stripe_loan_paydown_deducted_at]).to_date,
        before_cents: balance&.holding_amount_cents, deduction_cents: credit.amount_cents,
        after_cents: balance && balance.holding_amount_cents + credit.amount_cents }
    end

    def already_applied(credit)
      { status: :already_applied, credit_id: credit.id, balance_id: credit.balance_id }
    end
end
