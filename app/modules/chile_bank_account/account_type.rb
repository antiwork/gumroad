# frozen_string_literal: true

module ChileBankAccount::AccountType
  CHECKING = "checking"
  SAVINGS = "savings"

  def self.all
    [
      CHECKING,
      SAVINGS
    ]
  end
end
