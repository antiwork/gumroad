# frozen_string_literal: true

class AddSupportEmailToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :support_email, :string, null: true, default: nil
  end
end
