# frozen_string_literal: true

class CreateAustraliaBacktaxEmailInfos < ActiveRecord::Migration[7.0]
  def change
    create_table :australia_backtax_email_infos do |t|
      t.bigint :user_id
      t.string "email_name"
      t.datetime "sent_at"
      t.timestamps

      t.index [:user_id]
    end
  end
end
