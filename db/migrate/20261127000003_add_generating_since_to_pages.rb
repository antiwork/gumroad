# frozen_string_literal: true

class AddGeneratingSinceToPages < ActiveRecord::Migration[7.1]
  def change
    add_column :pages, :generating_since, :datetime
  end
end
