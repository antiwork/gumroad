# frozen_string_literal: true

class AddSlugToInstallments < ActiveRecord::Migration
  def up
    add_column :installments, :slug, :string
    add_index :installments, :slug, unique: true
  end

  def down
    remove_column :installments, :slug
  end
end
