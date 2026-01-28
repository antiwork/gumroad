# frozen_string_literal: true

class AddCompletedAtToPostEmailBlast < ActiveRecord::Migration[4.2]
  def change
    add_column :post_email_blasts, :completed_at, :datetime
  end
end
