# frozen_string_literal: true

class AddUserCategories < ActiveRecord::Migration
  def change
    create_table(:user_categorizations) do |t|
      t.belongs_to(:category)
      t.belongs_to(:user)
      t.timestamps
    end
    add_index(:user_categorizations, :category_id)
    add_index(:user_categorizations, :user_id)
  end
end
