# frozen_string_literal: true

class AddRecipientFilterToPostEmailBlasts < ActiveRecord::Migration[7.1]
  def change
    add_column :post_email_blasts, :recipient_filter, :string
  end
end
