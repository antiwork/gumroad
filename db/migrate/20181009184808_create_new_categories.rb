# frozen_string_literal: true

class CreateNewCategories < ActiveRecord::Migration
  CATEGORY_NAMES = %w(comics drawing animation audio games photography comedy crafts food design dance sports)

  def up
    CATEGORY_NAMES.each do |category_name|
      category = Category.new
      category.name = category_name
      category.save!
    end
  end

  def down
    CATEGORY_NAMES.each do |category_name|
      Category.where(name: category_name).destroy_all
    end
  end
end
