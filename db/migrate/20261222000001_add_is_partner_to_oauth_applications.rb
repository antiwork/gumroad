# frozen_string_literal: true

class AddIsPartnerToOauthApplications < ActiveRecord::Migration[8.1]
  # Renumbered after main took this branch's earlier numbers, so a preview database that ran one of
  # them already has the column. Those numbers are main's migrations now, so down cannot use them to
  # tell who added the column.
  def change
    add_column :oauth_applications, :is_partner, :boolean, default: false, null: false, if_not_exists: true
  end
end
