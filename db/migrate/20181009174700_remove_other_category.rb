# frozen_string_literal: true

class RemoveOtherCategory < ActiveRecord::Migration
  def up
    Category.where(name: "other").destroy_all
  end

  def down
    category = Category.new
    category.name = "other"
    category.save!
  end
end
