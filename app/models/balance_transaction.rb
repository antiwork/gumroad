# frozen_string_literal: true

# A record that records each change to a Balance record.
# Positive amount_cents represent deposited into the Balance.
# Negative amount_cents represent money withdrawn from the Balance.
class BalanceTransaction < ApplicationRecord
  include Immutable
  include ExternalId

  class Amount
    # The currency of the amount.
    attr_accessor :currency

    # The gross amount of money that was collected or received prior to fees, taxes and affiliate portions being taken out (in the currency).
    attr_accessor :gross_cents

    # The net amount of money that the user has earned towards their balance (in the currency).
    attr_accessor :net_cents

    def initialize(currency:, gross_cents:, net_cents:)
      @currency = currency
      @gross_cents = gross_cents
      @net_cents = net_cents
    end

    # When canonical_issued_amount is supplied (buyer-presentment charges), "issued amount"
    # here means the canonical seller/accounting issued amount, not the processor-issued
    # presentment amount — the processor issued e.g. CAD, but balances stay canonical.
    def self.create_issued_amount_for_affiliate(flow_of_funds:, issued_affiliate_cents:, canonical_issued_amount: nil)
      new(
        currency: canonical_issued_amount&.currency || flow_of_funds.gumroad_amount.currency,
        gross_cents: issued_affiliate_cents,
        net_cents: issued_affiliate_cents
      )
    end

    def self.create_holding_amount_for_affiliate(flow_of_funds:, issued_affiliate_cents:, canonical_issued_amount: nil)
      new(
        currency: canonical_issued_amount&.currency || flow_of_funds.gumroad_amount.currency,
        gross_cents: issued_affiliate_cents,
        net_cents: issued_affiliate_cents
      )
    end

    def self.create_issued_amount_for_seller(flow_of_funds:, issued_net_cents:, canonical_issued_amount: nil)
      issued_gross_amount = canonical_issued_amount || flow_of_funds.issued_amount

      new(
        currency: issued_gross_amount.currency,
        gross_cents: issued_gross_amount.cents,
        net_cents: issued_net_cents
      )
    end

    # `merchant_account` is what tells a Gumroad-held balance from a connected-account one. The
    # two need different answers from the same flow of funds on a buyer-presentment charge, so
    # without the account this method cannot be correct for both (gumroad-private#1471).
    def self.create_holding_amount_for_seller(flow_of_funds:, issued_net_cents:, canonical_issued_amount: nil, merchant_account: nil)
      if flow_of_funds.merchant_account_gross_amount
        new(
          currency: flow_of_funds.merchant_account_gross_amount.currency,
          gross_cents: flow_of_funds.merchant_account_gross_amount.cents,
          net_cents: flow_of_funds.merchant_account_net_amount.cents
        )
      elsif canonical_issued_amount && flow_of_funds.settled_amount && !gumroad_held?(merchant_account)
        # A buyer-presentment charge into a seller's own connected account. There the holding
        # amount describes that account's own balance, which really is denominated in the
        # currency Stripe settled, so the settled currency is the right label. Deliberately NOT
        # used for Gumroad-held funds — see below.
        new(
          currency: flow_of_funds.settled_amount.currency,
          gross_cents: flow_of_funds.settled_amount.cents,
          net_cents: issued_net_cents
        )
      else
        # Gumroad-held funds land here, and for them the holding amount means something
        # different from what it means on a connected account.
        #
        # For funds Gumroad holds, `holding_*` is Gumroad's own accounting record of what it
        # owes this seller — a liability, always denominated in USD, because USD is the currency
        # every Gumroad-held payout is computed and wired in. It is deliberately NOT a
        # description of which currency Stripe is physically sitting on. Stripe's platform
        # account does hold real foreign-currency balances (a EUR charge can settle and stay in
        # EUR), but that is an account-level treasury position covering all sellers at once, not
        # a per-seller fact, and nothing about paying one seller can be derived from it.
        #
        # So `settled_amount` is the wrong source here even when it is factually what Stripe
        # settled: on a buyer-presentment charge it is the currency the *buyer* was charged in,
        # which says nothing about the size of Gumroad's liability to the seller.
        #
        # Getting this wrong blocks money rather than merely mislabelling it. Both payout
        # processors require Gumroad-held balances to be USD, and they fail in different ways:
        #
        #   - StripePayoutProcessor#prepare_payment_and_set_amount rejects a non-USD
        #     Gumroad-held balance, and since its is_balance_payable admits every Gumroad-held
        #     balance regardless of currency, the bad row is pulled into the payout and fails the
        #     seller's *whole* payment with currency_mismatch — taking their correctly-labelled
        #     USD balances down with it.
        #   - PaypalPayoutProcessor.is_balance_payable requires USD, so it drops the bad row
        #     before a payment is ever built. The seller is quietly short-paid with no failure
        #     recorded anywhere.
        #
        # The canonical issued amount is the liability: the USD amount the seller earned, which
        # is exactly what Gumroad owes them.
        issued_gross_amount = canonical_issued_amount || flow_of_funds.issued_amount

        new(
          currency: issued_gross_amount.currency,
          gross_cents: issued_gross_amount.cents,
          net_cents: issued_net_cents
        )
      end
    end

    # Whether Gumroad itself is holding these funds, rather than a seller's own connected
    # Stripe account.
    #
    # Returns false when no merchant account is given, which keeps the pre-existing behaviour for
    # the two Onetime services that don't pass one (RebuildsSellerSettlementAmounts and
    # BackfillSelfAffiliateDroppedProceeds). Both already build a USD flow of funds for a
    # Gumroad-held purchase, so they get a USD holding amount either way. Every caller that books a
    # seller balance from a live charge passes the account.
    def self.gumroad_held?(merchant_account)
      return false if merchant_account.nil?

      merchant_account.holder_of_funds == HolderOfFunds::GUMROAD
    end
    private_class_method :gumroad_held?
  end

  MAX_ATTEMPTS_TO_UPDATE_BALANCE = 3
  private_constant :MAX_ATTEMPTS_TO_UPDATE_BALANCE

  belongs_to :user
  belongs_to :merchant_account
  belongs_to :balance, optional: true

  # Belongs to one of the following: purchase, dispute, refund, credit.
  belongs_to :purchase, optional: true
  belongs_to :dispute, optional: true
  belongs_to :refund, optional: true
  belongs_to :credit, optional: true

  # The balance_id should never be changed once it's set, but it gets set after the initial BalanceTransaction record is saved and so must be marked as mutable
  # so that it can be set after the initial save.
  attr_mutable :balance_id

  validate :validate_exactly_one_of_purchase_dispute_refund_credit_is_present

  # Public: Creates a balance transaction for a user and mutates the User's balance and Balance objects.
  # The merchant account should be the account that the funds are being held in, and for a purchase this is simply the same merchant account as the purchase.
  #
  # issued_amount is the money that was issued by an credit card issuer to the merchant account, for a purchase it will be the amount that was actually
  # charged to the buyers card, for a refund it will be the amount actually returned to the issuer, etc.
  #
  # holding_amount is the money that was collected and is actually being held, expressed in the
  # currency that account's balance is denominated in.
  #
  # What that means depends on who holds the funds, and the two are not the same kind of fact:
  #
  #   - A seller's own connected account (holder_of_funds STRIPE or CREATOR): the holding amount
  #     describes that account's balance, so it carries the account's own currency (CAD, AUD,
  #     GBP, etc) — the amount settled into it after the charge was authorized and completed.
  #   - Gumroad-held funds (holder_of_funds GUMROAD): the holding amount is Gumroad's canonical
  #     record of what it owes the seller, and is ALWAYS USD. It is a liability, not a statement
  #     about which currency Stripe is physically holding. Stripe's platform account does carry
  #     real foreign-currency balances — a EUR charge can settle and stay in EUR — but that is an
  #     account-level treasury position spanning every seller, and it is not what these fields
  #     record. Payouts of Gumroad-held funds are computed and wired in USD, and both payout
  #     processors reject a Gumroad-held balance that is not USD, so a foreign currency here
  #     blocks the seller's money (see gumroad-private#1471).
  #
  # Returns the BalanceTransaction, which will have an association to the `Balance` affected.
  def self.create!(user:, merchant_account:, purchase: nil, refund: nil, dispute: nil, credit: nil, issued_amount:, holding_amount:, update_user_balance: true)
    balance_transaction = new
    balance_transaction.user = user
    balance_transaction.merchant_account = merchant_account
    balance_transaction.purchase = purchase
    balance_transaction.refund = refund
    balance_transaction.dispute = dispute
    balance_transaction.credit = credit

    balance_transaction.issued_amount_currency = issued_amount.currency
    balance_transaction.issued_amount_gross_cents = issued_amount.gross_cents
    balance_transaction.issued_amount_net_cents = issued_amount.net_cents

    balance_transaction.holding_amount_currency = holding_amount.currency
    balance_transaction.holding_amount_gross_cents = holding_amount.gross_cents
    balance_transaction.holding_amount_net_cents = holding_amount.net_cents

    balance_transaction.save!

    # The balances are updated outside of the save so that Balance selection occurs outside of a transaction. Because balance selection involves the selection
    # and locking of balances and that occurs concurrently in other threads for payout, refund, etc, there is the possibility for deadlock if the selection
    # and locking occurs within a transaction that may implicitly lock other records. For this reason it's safer to save the BalanceTransaction and complete
    # it's transaction, and then do the selection outside of a transaction, ensuring that we only lock on the Balance object when updating it.
    if update_user_balance
      balance_transaction.update_balance!
    end

    balance_transaction
  end

  # Public: Update the balance for this balance transaction, selecting the most appropriate balance given the type of object it's associated with.
  # Selection of a balance may be attempted multiple times in the rare case of the balance state changing between when we select and lock it and
  # it's in a state where the amounts cannot be changed. If the maximum number of attempts is exhausted, the ActiveRecord::RecordInvalid error from the attempt
  # to change the amount will be passed up.
  def update_balance!
    balance = find_or_create_balance
    balance.with_lock do
      balance.increment(:amount_cents, issued_amount_net_cents)
      balance.increment(:holding_amount_cents, holding_amount_net_cents)
      balance.save!
      self.balance = balance
      save!
    end
  rescue ActiveRecord::RecordInvalid => e
    # Saving the balance can fail if the balance's state changed between selection and locking, to a state invalid for changing the amounts.
    failed_count ||= 1
    logger.info("Updating balance for transaction #{id}: Balance #{balance.id} could not be saved. Failed count: #{failed_count} Exception:\n#{e}")
    failed_count += 1
    retry if failed_count < MAX_ATTEMPTS_TO_UPDATE_BALANCE
    raise
  rescue ActiveRecord::LockWaitTimeout => e
    lock_failed_count ||= 0
    lock_failed_count += 1
    logger.warn("Updating balance for transaction #{id}: Lock wait timeout on balance #{balance&.id}. Attempt: #{lock_failed_count}/#{MAX_ATTEMPTS_TO_UPDATE_BALANCE}")
    if lock_failed_count < MAX_ATTEMPTS_TO_UPDATE_BALANCE
      sleep(lock_failed_count * 0.5)
      retry
    end
    raise
  end

  # Public: Selects the most appropriate balance given the type of object this balance transaction is associated with.
  # Creates a balance if one does not already exists.
  # Returns the balance found or created.
  def find_or_create_balance
    # Working around Octopus choosing the slave db for all selects, even the ones with "FOR UPDATE"
    ApplicationRecord.connected_to(role: :writing) do
      unpaid_balances = Balance.where(
        user:,
        merchant_account:,
        currency: issued_amount_currency,
        holding_currency: holding_amount_currency,
        state: "unpaid"
      ).order(date: :asc)

      # attempt to find an existing balance this transaction can be applied to, as close to when the money first moved relating to this change in balance
      balance =
        if purchase
          unpaid_balances.where(date: purchase.succeeded_at.to_date).first
        elsif refund
          unpaid_balances.where(date: refund.purchase.succeeded_at.to_date).first || unpaid_balances.first
        elsif dispute
          unpaid_balances.where(date: dispute.disputable.dispute_balance_date).first || unpaid_balances.first
        elsif credit&.financing_paydown_purchase
          unpaid_balances.where(date: credit.financing_paydown_purchase.succeeded_at.to_date).first || unpaid_balances.first
        elsif credit&.fee_retention_refund
          unpaid_balances.first
        elsif credit
          unpaid_balances.first
        end

      # create the balance as a last resort
      if balance.nil?
        # get the date this balance transaction has occurred, based on the associated object
        occurred_at =
          if purchase
            purchase.succeeded_at.to_date
          elsif refund
            refund.created_at.to_date
          elsif dispute
            dispute.formalized_at.to_date
          elsif credit&.returned_payment
            credit.returned_payment.balances.order(date: :asc).first&.date || credit.created_at.to_date
          elsif credit
            credit.created_at.to_date
          end

        # create a new balance at the date this balance transaction occurred
        balance =
          begin
            Balance.create!(
              user:,
              merchant_account:,
              currency: issued_amount_currency,
              holding_currency: holding_amount_currency,
              date: occurred_at
            )
          rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
            logger.info("Creating balance for transaction #{id}: Balance already exists in the DB; we are not duplicating it. Exception: #{e.message}")
            unpaid_balances.where(date: occurred_at).first
          end
      end

      raise BalanceCouldNotBeFoundOrCreated, id if balance.nil?

      balance
    end
  end

  private
    def validate_exactly_one_of_purchase_dispute_refund_credit_is_present
      exactly_one_is_present = purchase.present? ^ dispute.present? ^ refund.present? ^ credit.present?
      return if exactly_one_is_present

      errors.add(:base, "can only have one of: purchase, dispute, refund, credit")
    end

    class BalanceCouldNotBeFoundOrCreated < GumroadRuntimeError
      def initialize(balance_transaction_id)
        super("A suitable balance for transaction #{balance_transaction_id} could not be found or created.")
      end
    end
end
