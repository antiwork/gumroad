# frozen_string_literal: true

class AddFailureReasonToPayments < ActiveRecord::Migration
  def change
    add_column :payments, :failure_reason, :string
  end
end
