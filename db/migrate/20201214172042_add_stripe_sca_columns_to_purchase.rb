# frozen_string_literal: true

class AddStripeScaColumnsToPurchase < ActiveRecord::Migration[6.0]
  def up
    # Using raw SQL due to a bug in departure gem: https://github.com/gumroad/web/pull/17299#issuecomment-786054996
    execute <<~SQL
      ALTER TABLE purchases
        ADD COLUMN processor_payment_intent_id VARCHAR(255),
        ADD COLUMN processor_setup_intent_id VARCHAR(255),
        ADD COLUMN price_id INT(11),
        ADD COLUMN recommended_by VARCHAR(255),
        ADD INDEX index_purchases_on_processor_payment_intent_id (processor_payment_intent_id),
        ADD INDEX index_purchases_on_processor_setup_intent_id (processor_setup_intent_id)
    SQL
  end

  def down
    change_table :purchases do |t|
      t.remove :processor_payment_intent_id
      t.remove :processor_setup_intent_id
      t.remove :recommended_by
      t.remove :price_id
    end
  end
end
