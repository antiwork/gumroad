# frozen_string_literal: true

class CreateProductPublishSchedules < ActiveRecord::Migration[7.1]
  def change
    create_table :product_publish_schedules do |t|
      t.bigint :product_id, null: false
      t.bigint :scheduled_by_id, null: false
      t.datetime :publish_at, null: false
      t.string :status, default: "scheduled", null: false
      t.datetime :claimed_at
      t.datetime :published_at
      t.string :failure_message
      t.datetime :notice_sent_at
      t.timestamps

      t.index :product_id, unique: true
      t.index [:status, :publish_at]
    end
  end
end
