# frozen_string_literal: true

class CreateAudienceExports < ActiveRecord::Migration[7.1]
  def change
    create_table :audience_exports do |t|
      t.bigint :seller_id, null: false, index: true
      t.bigint :recipient_id, null: false, index: true
      t.text :json_data
      t.timestamps
    end
  end
end
