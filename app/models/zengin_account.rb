# frozen_string_literal: true

# Zengin was the bank transfer system we used for native Japan payouts before
# moving them to Stripe. The payout rail itself is retired (see
# PayoutProcessorType::ZENGIN), but legacy bank_accounts rows with
# type = "ZenginAccount" still exist in the database. This class must stay so
# ActiveRecord's single-table inheritance can instantiate those rows — deleting
# it raises ActiveRecord::SubclassNotFound whenever such a record is loaded.
class ZenginAccount < BankAccount
  BANK_ACCOUNT_TYPE = "ZENGIN"

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end
end
