# frozen_string_literal: true

class CreateInstallments < ActiveRecord::Migration
  def change
    create_table :installments do |t|
      t.integer :link_id
      t.text    :message
      t.text    :url
      t.timestamps
    end
  end
end
