# frozen_string_literal: true

class AddProcessorPaymentIntentIdToServiceCharges < ActiveRecord::Migration[6.0]
  def up
    # Using raw SQL due to a bug in departure gem: https://github.com/gumroad/web/pull/17299#issuecomment-786054996
    execute <<~SQL
      ALTER TABLE service_charges
        ADD COLUMN processor_payment_intent_id VARCHAR(255),
        ADD INDEX index_service_charges_on_processor_payment_intent_id (processor_payment_intent_id)
    SQL
  end

  def down
    remove_column :service_charges, :processor_payment_intent_id
  end
end
