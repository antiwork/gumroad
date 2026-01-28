# frozen_string_literal: true

class RemoveOtherCategory < ActiveRecord::Migration[4.2]
  def up
    Category.where(name: "other").destroy_all
  end

  def down
    category = Category.new
    category.name = "other"
    category.save!
  end
end
