# frozen_string_literal: true

class Credit < ApplicationRecord
  include CurrencyHelper, JsonData

  belongs_to :user, optional: true
  belongs_to :merchant_account, optional: true
  belongs_to :crediting_user, class_name: "User", optional: true
  belongs_to :balance, optional: true
  belongs_to :chargebacked_purchase, class_name: "Purchase", optional: true
  belongs_to :dispute, optional: true
  belongs_to :returned_payment, class_name: "Payment", optional: true
  belongs_to :refund, optional: true
  belongs_to :financing_paydown_purchase, class_name: "Purchase", optional: true
  belongs_to :fee_retention_refund, class_name: "Refund", optional: true
  belongs_to :backtax_agreement, optional: true

  has_one :balance_transaction

  after_create :add_comment

  validates :user, :merchant_account, presence: true

  validate :validate_associated_entity

  attr_json_data_accessor :stripe_loan_paydown_id

  def self.create_for_credit!(user:, amount_cents:, crediting_user:)
    credit = new
    credit.user = user
    credit.merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    credit.amount_cents = amount_cents
    credit.crediting_user = crediting_user
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_dispute_won!(user:, merchant_account:, dispute:, chargedback_purchase:, balance_transaction_issued_amount:, balance_transaction_holding_amount:)
    credit = new
    credit.user = user
    credit.merchant_account = merchant_account
    credit.amount_cents = balance_transaction_issued_amount.net_cents
    credit.chargebacked_purchase = chargedback_purchase
    credit.dispute = dispute
    credit.save!

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_issued_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_returned_payment_difference!(user:, merchant_account:, returned_payment:, difference_amount_cents:)
    credit = new
    credit.user = user
    credit.merchant_account = merchant_account
    credit.amount_cents = 0
    credit.returned_payment = returned_payment
    credit.save!

    balance_transaction_issued_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: 0,
      net_cents: 0
    )
    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: returned_payment.currency,
      gross_cents: difference_amount_cents,
      net_cents: difference_amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_issued_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_vat_refund!(refund:)
    total_refunded_vat_amount = refund.total_transaction_cents
    purchase_amount = refund.purchase.total_transaction_cents
    gumroad_amount = refund.purchase.total_transaction_amount_for_gumroad_cents
    refunded_gumroad_amount = gumroad_amount * (total_refunded_vat_amount.to_f / purchase_amount)
    credit_amount = total_refunded_vat_amount - refunded_gumroad_amount.to_i

    credit = new
    credit.user = refund.purchase.seller
    credit.merchant_account = refund.purchase.charge_processor_id == StripeChargeProcessor.charge_processor_id ?
                                  MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) :
                                  MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id)
    credit.amount_cents = credit_amount
    credit.refund = refund
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  # When we refund VAT for a purchase paid via PayPal Native, we create a positive credit for the creator
  # (`Credit.create_for_vat_refund!`) to compensate for the portion of the VAT that was refunded
  # from their PayPal/Stripe Connect balance (since there's no way to specify that the refund should be taken out entirely
  # from the Gumroad's portion of the purchase, see https://github.com/gumroad/web/issues/20820#issuecomment-1021042784).
  #
  # When a purchase with VAT refund is further partially or fully refunded, we need to apply proportional negative credit
  # to the creator's balance because these refunds will be partially taken out from the Gumroad's portion
  # (for which we have already given the creator credit during the VAT refund).
  #
  # If during VAT refund we apply $X credit for the user, and afterwards the purchase is fully refunded, we should apply -$X
  # credit to even things out.
  def self.create_for_vat_exclusive_refund!(refund:)
    # Only create negative credit if:
    # - VAT was charged initially
    # - the refund does not include any VAT (meaning that VAT was refunded separately from the body of the purchase
    #   and there's no more VAT to refund left)
    return if refund.gumroad_tax_cents > 0 || refund.purchase.gumroad_tax_cents == 0

    total_refunded_amount = refund.total_transaction_cents

    purchase_gumroad_amount = refund.purchase.total_transaction_amount_for_gumroad_cents
    purchase_gumroad_tax_amount = refund.purchase.gumroad_tax_cents
    purchase_gumroad_amount_sans_vat = purchase_gumroad_amount - purchase_gumroad_tax_amount

    purchase_total_amount = refund.purchase.total_transaction_cents
    purchase_amount_sans_vat = refund.purchase.price_cents

    refunded_gumroad_amount = purchase_gumroad_amount * (total_refunded_amount.to_f / purchase_total_amount)
    expected_refunded_gumroad_amount = purchase_gumroad_amount_sans_vat * (total_refunded_amount.to_f / purchase_amount_sans_vat)

    # Negative credit amount
    amount_to_credit = (expected_refunded_gumroad_amount - refunded_gumroad_amount).round

    credit = new
    credit.user = refund.purchase.seller
    credit.merchant_account = refund.purchase.charge_processor_id == StripeChargeProcessor.charge_processor_id ?
                                  MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) :
                                  MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id)
    credit.amount_cents = amount_to_credit
    credit.refund = refund
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )
    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_financing_paydown!(purchase:, amount_cents:, merchant_account:, stripe_loan_paydown_id:)
    return unless stripe_loan_paydown_id.present?

    user = merchant_account.user
    return if user.credits.where("json_data->'$.stripe_loan_paydown_id' = ?", stripe_loan_paydown_id).exists?

    credit = new
    credit.user = user
    credit.amount_cents = amount_cents
    credit.merchant_account = merchant_account
    credit.financing_paydown_purchase = purchase
    credit.stripe_loan_paydown_id = stripe_loan_paydown_id
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit.get_usd_cents(credit.merchant_account.currency, credit.amount_cents),
      net_cents: credit.get_usd_cents(credit.merchant_account.currency, credit.amount_cents)
    )

    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: credit.merchant_account.currency,
      gross_cents: credit.amount_cents,
      net_cents: credit.amount_cents
    )

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_bank_debit_on_stripe_account!(amount_cents:, merchant_account:)
    create_for_balance_change_on_stripe_account!(amount_cents_holding_currency: amount_cents, merchant_account:)
  end

  def self.create_for_manual_paydown_on_stripe_loan!(amount_cents:, merchant_account:, stripe_loan_paydown_id:)
    credit = create_for_balance_change_on_stripe_account!(amount_cents_holding_currency: amount_cents, merchant_account:)
    credit.update!(stripe_loan_paydown_id:)
    credit
  end

  def self.create_for_balance_change_on_stripe_account!(amount_cents_holding_currency:, merchant_account:, amount_cents_usd: nil)
    credit = new
    credit.user = merchant_account.user
    credit_amount_cents_usd = amount_cents_usd.presence || credit.get_usd_cents(merchant_account.currency, amount_cents_holding_currency)
    credit.amount_cents = credit_amount_cents_usd
    credit.merchant_account = merchant_account
    credit.crediting_user = User.find(GUMROAD_ADMIN_ID)
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: credit_amount_cents_usd,
      net_cents: credit_amount_cents_usd
    )

    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: credit.merchant_account.currency,
      gross_cents: amount_cents_holding_currency,
      net_cents: amount_cents_holding_currency
    )

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_refund_fee_retention!(refund:)
    # We retain the payment processor fee (2.9% + 30c) and the Gumroad fee (10% + any discover fee) in case of refunds.
    # For Stripe Connect sales, the application fee includes the Gumroad fee, the VAT/sales tax,
    # and the affiliate credit. We debit connected accounts for the full application fee, so we add a positive credit
    # to the seller's balance. We have to do it this way because we don't have the seller's balance in our control,
    # so adding a negative credit to their account for Gumroad's fee wouldn't work because there likely wouldn't be a
    # balance to collect from.
    unless refund.purchase.charged_using_gumroad_merchant_account?
      purchase = refund.purchase
      application_fee_refundable_portion = purchase.gumroad_tax_cents + purchase.affiliate_credit_cents
      return if application_fee_refundable_portion.zero?

      credit = new
      credit.user = purchase.seller
      credit.amount_cents = (application_fee_refundable_portion * (refund.amount_cents.to_f / purchase.price_cents)).round
      credit.merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      credit.fee_retention_refund = refund
      credit.save!

      balance_transaction_amount = BalanceTransaction::Amount.new(
        currency: Currency::USD,
        gross_cents: credit.amount_cents,
        net_cents: credit.amount_cents
      )
      balance_transaction = BalanceTransaction.create!(
        user: credit.user,
        merchant_account: credit.merchant_account,
        credit:,
        issued_amount: balance_transaction_amount,
        holding_amount: balance_transaction_amount
      )

      credit.balance = balance_transaction.balance
      credit.save!

      return credit
    end

    credit = new
    credit.user = refund.purchase.seller
    # If purchase.processor_fee_cents is present (most cases), we use it to calculate the fee to be retained.
    # We also check that purchase.processor_fee_cents_currency is 'usd' here, although that should always be the case,
    # as we are only doing this calculation for sales via gumroad-controlled Stripe accounts and Braintree,
    # and in both those cases transactions are always in USD.
    # If purchase.processor_fee_cents is not present for some reason (rare case), we calculate the fee amount,
    # that is to be retained, using the fee percentage used in Purchase#calculate_fees.
    credit.amount_cents = if refund.purchase.processor_fee_cents.present? && refund.purchase.processor_fee_cents_currency == "usd"
      -(refund.purchase.processor_fee_cents * (refund.amount_cents.to_f / refund.purchase.price_cents)).round
    else
      -(refund.amount_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + (Purchase::PROCESSOR_FIXED_FEE_CENTS * refund.amount_cents.to_f / refund.purchase.price_cents)).round
    end
    credit.merchant_account = refund.purchase.merchant_account
    credit.fee_retention_refund = refund
    credit.save!

    refund.retained_fee_cents = credit.amount_cents.abs
    refund.save!

    reversed_amount_cents_in_usd = credit.amount_cents
    reversed_amount_cents_in_holding_currency = credit.usd_cents_to_currency(credit.merchant_account.currency, credit.amount_cents)

    # For Stripe sales that use a gumroad-managed custom connect account, we debit the Stripe account for the fee amount.
    if credit.merchant_account.holder_of_funds == HolderOfFunds::STRIPE && credit.merchant_account.country == Compliance::Countries::USA.alpha2
      # For gumroad-controlled Stripe accounts from the US, we can make new debit transfers.
      # So we transfer the retained fee back to Gumroad's Stripe platform account.
      Stripe::Transfer.create({ amount: credit.amount_cents.abs, currency: "usd", destination: Stripe::Account.retrieve.id, },
                              { stripe_account: credit.merchant_account.charge_processor_merchant_id })
    elsif credit.merchant_account.holder_of_funds == HolderOfFunds::STRIPE
      # For non-US gumroad-controlled Stripe accounts, we cannot make debit transfers.
      # So we try and reverse the retained fee amount from one of the old transfers made to that Stripe account.
      net_amount_on_stripe_in_holding_currency = StripeChargeProcessor.debit_stripe_account_for_refund_fee(credit:)
      reversed_amount_cents_in_holding_currency = -net_amount_on_stripe_in_holding_currency if net_amount_on_stripe_in_holding_currency.present?
    end

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: reversed_amount_cents_in_usd,
      net_cents: reversed_amount_cents_in_usd
    )

    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: credit.merchant_account.currency,
      gross_cents: reversed_amount_cents_in_holding_currency,
      net_cents: reversed_amount_cents_in_holding_currency
    )

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def self.create_for_partial_refund_transfer_reversal!(amount_cents_usd:, amount_cents_holding_currency:, merchant_account:)
    credit = new
    credit.user = merchant_account.user
    credit.amount_cents = amount_cents_usd
    credit.merchant_account = merchant_account
    credit.crediting_user = User.find(GUMROAD_ADMIN_ID)
    credit.save!

    balance_transaction_amount = BalanceTransaction::Amount.new(
      currency: Currency::USD,
      gross_cents: amount_cents_usd,
      net_cents: amount_cents_usd
    )

    balance_transaction_holding_amount = BalanceTransaction::Amount.new(
      currency: credit.merchant_account.currency,
      gross_cents: amount_cents_holding_currency,
      net_cents: amount_cents_holding_currency
    )

    balance_transaction = BalanceTransaction.create!(
      user: credit.user,
      merchant_account: credit.merchant_account,
      credit:,
      issued_amount: balance_transaction_amount,
      holding_amount: balance_transaction_holding_amount
    )

    credit.balance = balance_transaction.balance
    credit.save!
    credit
  end

  def notify_user
    ContactingCreatorMailer.credit_notification(user.id, amount_cents).deliver_later(queue: "critical")
  end

  def add_comment
    return if fee_retention_refund.present?

    comment_attrs = {
      content: "issued #{formatted_dollar_amount(amount_cents)} credit.",
      comment_type: :credit
    }
    if crediting_user
      comment_attrs[:author_id] = crediting_user_id
    elsif chargebacked_purchase
      comment_attrs[:author_name] = "AutoCredit Chargeback Won (#{chargebacked_purchase.id})"
    elsif returned_payment
      comment_attrs[:author_name] = "AutoCredit Returned Payment (#{returned_payment.id})"
      comment_attrs[:content] = "issued adjustment due to currency conversion differences when payment #{returned_payment.id} returned."
    elsif refund
      comment_attrs[:author_name] = "AutoCredit PayPal Connect VAT refund (#{refund.purchase.id})"
    end
    user.comments.create(comment_attrs)
  end

  private
    def validate_associated_entity
      return if crediting_user || chargebacked_purchase || returned_payment || refund || financing_paydown_purchase || fee_retention_refund || backtax_agreement

      errors.add(:base, "A crediting user, chargebacked purchase, returned payment, refund, financing_paydown_purchase, fee_retention_refund or backtax_agreement must be provided.")
    end
end
