# frozen_string_literal: true

class AddBaseVariantToWorkflows < ActiveRecord::Migration
  def change
    add_reference :workflows, :base_variant, index: true
  end
end
