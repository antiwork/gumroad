# frozen_string_literal: true

class StandardizeSubscriptions < ActiveRecord::Migration[7.1]
  def up
    change_table :subscriptions, bulk: true do |t|
      t.change :id, :bigint, null: false, auto_increment: true
      t.change :link_id, :bigint
      t.change :user_id, :bigint
      t.change :cancelled_at, :datetime, limit: 6
      t.change :failed_at, :datetime, limit: 6
      t.change :created_at, :datetime, limit: 6
      t.change :updated_at, :datetime, limit: 6
      t.change :flags, :bigint, default: 0, null: false
      t.change :user_requested_cancellation_at, :datetime, limit: 6
      t.change :ended_at, :datetime, limit: 6
      t.change :last_payment_option_id, :bigint
      t.change :credit_card_id, :bigint
      t.change :deactivated_at, :datetime, limit: 6
      t.change :free_trial_ends_at, :datetime, limit: 6

      t.remove :purchase_id
    end
  end

  def down
    change_table :subscriptions, bulk: true do |t|
      t.change :id, :integer, null: false, auto_increment: true
      t.change :link_id, :integer
      t.change :user_id, :integer
      t.change :cancelled_at, :datetime, precision: nil
      t.change :failed_at, :datetime, precision: nil
      t.change :created_at, :datetime, precision: nil
      t.change :updated_at, :datetime, precision: nil
      t.change :flags, :integer, default: 0, null: false
      t.change :user_requested_cancellation_at, :datetime, precision: nil
      t.change :ended_at, :datetime, precision: nil
      t.change :last_payment_option_id, :integer
      t.change :credit_card_id, :integer
      t.change :deactivated_at, :datetime, precision: nil
      t.change :free_trial_ends_at, :datetime, precision: nil

      t.integer :purchase_id, after: :updated_at
    end
  end
end
