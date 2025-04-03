# frozen_string_literal: true

class AddAffiliateBasisPointsToAffiliatesLinks < ActiveRecord::Migration[7.0]
  def change
    add_column :affiliates_links, :affiliate_basis_points, :integer
  end
end
