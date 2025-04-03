# frozen_string_literal: true

class AddDeletedAtToInstallments < ActiveRecord::Migration
  def change
    add_column :installments, :deleted_at, :datetime
  end
end
