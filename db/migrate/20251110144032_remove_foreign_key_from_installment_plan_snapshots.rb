# frozen_string_literal: true

class RemoveForeignKeyFromInstallmentPlanSnapshots < ActiveRecord::Migration[7.1]
  def change
    remove_foreign_key :installment_plan_snapshots, :payment_options
  end
end
