# frozen_string_literal: true

class AddAffiliateBasisPointsToAffiliatesLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :affiliates_links, :affiliate_basis_points, :integer
  end
end
