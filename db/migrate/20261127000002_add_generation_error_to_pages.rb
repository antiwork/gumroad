# frozen_string_literal: true

class AddGenerationErrorToPages < ActiveRecord::Migration[7.1]
  def change
    add_column :pages, :generation_error, :string
  end
end
