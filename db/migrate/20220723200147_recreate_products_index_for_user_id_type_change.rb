# frozen_string_literal: true

class RecreateProductsIndexForUserIdTypeChange < ActiveRecord::Migration[4.2]
  def up
    return unless Rails.env.development?

    Link.__elasticsearch__.create_index!(force: true)
    Link.import
  end
end
