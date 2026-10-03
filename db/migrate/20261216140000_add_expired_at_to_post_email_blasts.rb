# frozen_string_literal: true

class AddExpiredAtToPostEmailBlasts < ActiveRecord::Migration[7.1]
  def change
    add_column :post_email_blasts, :expired_at, :datetime
  end
end
