# frozen_string_literal: true

module ColombiaBankAccount::AccountType
  CHECKING = "checking"
  SAVINGS = "savings"

  def self.all
    [
      CHECKING,
      SAVINGS
    ]
  end
end
