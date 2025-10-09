# frozen_string_literal: true

class AddInstallmentConfigToPaymentOptions < ActiveRecord::Migration[7.1]
  def change
    Alterity.disable do
      add_column :payment_options, :number_of_installments, :integer
      add_column :payment_options, :recurrence, :string
    end

    reversible do |dir|
      dir.up do
        execute <<-SQL.squish
          UPDATE payment_options po
          INNER JOIN product_installment_plans pip
            ON po.product_installment_plan_id = pip.id
          SET po.number_of_installments = pip.number_of_installments,
              po.recurrence = pip.recurrence
          WHERE po.product_installment_plan_id IS NOT NULL
            AND po.number_of_installments IS NULL
        SQL
      end
    end
  end
end
