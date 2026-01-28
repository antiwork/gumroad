# frozen_string_literal: true

class AddPublishedAtToInstallments < ActiveRecord::Migration[4.2]
  def change
    add_column :installments, :published_at, :datetime
  end
end
