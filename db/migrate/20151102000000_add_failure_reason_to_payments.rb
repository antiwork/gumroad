# frozen_string_literal: true

class AddFailureReasonToPayments < ActiveRecord::Migration[4.2]
  def change
    add_column :payments, :failure_reason, :string
  end
end
