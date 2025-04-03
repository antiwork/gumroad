# frozen_string_literal: true

class AddTaxonomyIdToLinks < ActiveRecord::Migration[6.1]
  def change
    add_reference :links, :taxonomy
  end
end
