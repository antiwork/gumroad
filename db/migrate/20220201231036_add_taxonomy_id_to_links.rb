# frozen_string_literal: true

class AddTaxonomyIdToLinks < ActiveRecord::Migration[4.2]
  def change
    add_reference :links, :taxonomy
  end
end
