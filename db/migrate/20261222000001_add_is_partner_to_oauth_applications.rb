# frozen_string_literal: true

class AddIsPartnerToOauthApplications < ActiveRecord::Migration[8.1]
  # Renumbered after main took this branch's earlier numbers, so a preview database that ran one of
  # them already has the column. Those numbers are main's migrations now and cannot show who added the
  # column, so down keeps it while any application has partner access.
  def up
    add_column :oauth_applications, :is_partner, :boolean, default: false, null: false, if_not_exists: true
  end

  def down
    return if select_value("SELECT 1 FROM oauth_applications WHERE is_partner = TRUE LIMIT 1").present?

    remove_column :oauth_applications, :is_partner, if_exists: true
  end
end
