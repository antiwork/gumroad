# frozen_string_literal: true

class UpdateCategoryNames < ActiveRecord::Migration
  def up
    Category.where(name: "publishing").update_all(name: "writing")
    Category.where(name: "physical").update_all(name: "merchandise")
  end

  def down
    Category.where(name: "merchandise").update_all(name: "physical")
    Category.where(name: "writing").update_all(name: "publishing")
  end
end
