# frozen_string_literal: true

class AddAffiliateBasisPointsToOauthApplications < ActiveRecord::Migration[4.2]
  def change
    add_column :oauth_applications, :affiliate_basis_points, :integer
  end
end
