# frozen_string_literal: true

class AddPublishedAtToInstallments < ActiveRecord::Migration
  def change
    add_column :installments, :published_at, :datetime
  end
end
