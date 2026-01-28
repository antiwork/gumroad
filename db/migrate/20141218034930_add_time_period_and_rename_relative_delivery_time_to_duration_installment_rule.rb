# frozen_string_literal: true

class AddTimePeriodAndRenameRelativeDeliveryTimeToDurationInstallmentRule < ActiveRecord::Migration[4.2]
  def change
    add_column :installment_rules, :time_period, :string
    rename_column :installment_rules, :relative_delivery_time, :delayed_delivery_time
  end
end
