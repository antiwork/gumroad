# frozen_string_literal: true

class AddCorrelationIdToPayments < ActiveRecord::Migration[4.2]
  def change
    add_column :payments, :correlation_id, :string
  end
end
