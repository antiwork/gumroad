# frozen_string_literal: true

class AddCompletedAtToPostEmailBlast < ActiveRecord::Migration[7.0]
  def change
    add_column :post_email_blasts, :completed_at, :datetime
  end
end
