# frozen_string_literal: true

class AddAffiliateBasisPointsToOauthApplications < ActiveRecord::Migration
  def change
    add_column :oauth_applications, :affiliate_basis_points, :integer
  end
end
