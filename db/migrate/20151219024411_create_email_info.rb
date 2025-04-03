# frozen_string_literal: true

class CreateEmailInfo < ActiveRecord::Migration
  def change
    create_table :email_infos, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_general_ci" do |t|
      t.references  :user
      t.references  :purchase
      t.references  :installment

      t.string      :type
      t.string      :email_name
      t.string      :state
      t.datetime    :sent_at
      t.datetime    :delivered_at
      t.datetime    :opened_at
    end

    add_index :email_infos, :user_id
    add_index :email_infos, :purchase_id
    add_index :email_infos, :installment_id
  end
end
