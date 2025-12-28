# frozen_string_literal: true

class AddJsonDataToInstallmentPlanSnapshots < ActiveRecord::Migration[7.1]
  def change
    add_column :installment_plan_snapshots, :json_data, :text
  end
end
