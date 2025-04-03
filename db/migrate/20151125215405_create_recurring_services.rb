# frozen_string_literal: true

class CreateRecurringServices < ActiveRecord::Migration
  def change
    create_table :recurring_services, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.timestamps

      t.references      :user
      t.string          :type
      t.integer         :price_cents
      t.integer         :recurrence
      t.datetime        :failed_at
      t.datetime        :cancelled_at
      t.string          :state
      t.string          :json_data
    end

    add_index :recurring_services, :user_id
  end
end
