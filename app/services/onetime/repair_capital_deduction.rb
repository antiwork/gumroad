# frozen_string_literal: true

class Onetime::RepairCapitalDeduction
  def initialize(credit_id:, balance_transaction_id:, balance_id:, stripe_loan_paydown_id:, expected_amount_cents:, expected_balance_cents:, dry_run: true)
    @credit_id = credit_id
    @balance_transaction_id = balance_transaction_id
    @balance_id = balance_id
    @stripe_loan_paydown_id = stripe_loan_paydown_id
    @expected_amount_cents = expected_amount_cents
    @expected_balance_cents = expected_balance_cents
    @dry_run = dry_run
  end

  def process
    ApplicationRecord.connected_to(role: :writing) do
      balance = Balance.find(@balance_id)
      balance.with_lock do
        transaction = BalanceTransaction.lock.find(@balance_transaction_id)
        credit = Credit.lock.find(@credit_id)
        validate_records!(credit, transaction, balance)

        if transaction.balance_id == balance.id && credit.balance_id == balance.id
          next { status: :already_applied, credit_id: credit.id, balance_transaction_id: transaction.id, balance_id: balance.id }
        end
        raise "Capital deduction is already linked" if transaction.balance_id.present? || credit.balance_id.present?
        raise "Target balance is not unpaid" unless balance.unpaid?
        unless balance.amount_cents == @expected_balance_cents && balance.holding_amount_cents == @expected_balance_cents
          raise "Target balance amount has changed"
        end
        unless balance.balance_transactions.sum(:issued_amount_net_cents) == balance.amount_cents &&
               balance.balance_transactions.sum(:holding_amount_net_cents) == balance.holding_amount_cents
          raise "Target balance does not match its transactions"
        end

        result = {
          status: @dry_run ? :dry_run : :applied,
          credit_id: credit.id,
          balance_transaction_id: transaction.id,
          balance_id: balance.id,
          before_cents: balance.holding_amount_cents,
          deduction_cents: transaction.holding_amount_net_cents,
          after_cents: balance.holding_amount_cents + transaction.holding_amount_net_cents
        }
        unless @dry_run
          transaction.update_balance!(target_balance: balance)
          credit.update!(balance:)
          Rails.logger.info("[RepairCapitalDeduction] #{result.to_json}")
        end
        result
      end
    end
  end

  private
    def validate_records!(credit, transaction, balance)
      unless @expected_amount_cents.negative? && credit.amount_cents == @expected_amount_cents &&
             credit.stripe_loan_paydown_id.present? && credit.stripe_loan_paydown_id == @stripe_loan_paydown_id &&
             credit.financing_paydown_purchase&.succeeded_at.present?
        raise "Credit does not match the expected Capital deduction"
      end
      unless [credit.user_id, transaction.user_id, credit.financing_paydown_purchase.seller_id].all?(balance.user_id) &&
             [credit.merchant_account_id, transaction.merchant_account_id].all?(balance.merchant_account_id) &&
             credit.merchant_account.holder_of_funds == HolderOfFunds::STRIPE && credit.merchant_account.currency == Currency::USD
        raise "Capital deduction belongs to a different account"
      end
      unless transaction.credit_id == credit.id &&
             transaction.purchase_id.nil? && transaction.refund_id.nil? && transaction.dispute_id.nil? &&
             [transaction.issued_amount_currency, transaction.holding_amount_currency, balance.currency, balance.holding_currency].all?(Currency::USD) &&
             [transaction.issued_amount_gross_cents, transaction.issued_amount_net_cents,
              transaction.holding_amount_gross_cents, transaction.holding_amount_net_cents].all?(@expected_amount_cents)
        raise "Balance transaction does not match the expected deduction"
      end
      unless BalanceTransaction.where(credit_id: credit.id).count == 1 &&
             credit.user.credits.where("json_data->'$.stripe_loan_paydown_id' = ?", @stripe_loan_paydown_id).count == 1
        raise "Capital deduction has duplicate records"
      end
    end
end
