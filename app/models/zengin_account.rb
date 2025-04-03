# frozen_string_literal: true

class ZenginAccount < BankAccount
  # This class has been deprecated, as we no longer native Japan payouts via Zengin!

  BANK_ACCOUNT_TYPE = "ZENGIN"

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end
end
