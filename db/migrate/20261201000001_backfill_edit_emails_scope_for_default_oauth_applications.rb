# frozen_string_literal: true

class BackfillEditEmailsScopeForDefaultOauthApplications < ActiveRecord::Migration[7.1]
  OLD_PUBLIC_SCOPES = %w[edit_products view_sales mark_sales_as_shipped edit_sales revenue_share ifttt view_profile view_payouts view_tax_data account].freeze
  NEW_SCOPE = "edit_emails"

  def up
    oauth_applications.find_each do |application|
      scopes = application.scopes.to_s.split
      next if scopes.include?(NEW_SCOPE)
      next unless old_default_scopes?(scopes)

      scopes.insert(scopes.index("edit_products").to_i + 1, NEW_SCOPE)
      application.update_columns(scopes: scopes.join(" "), updated_at: Time.current)
    end
  end

  def down
    oauth_applications.find_each do |application|
      scopes = application.scopes.to_s.split
      next unless scopes.include?(NEW_SCOPE)
      next unless new_default_scopes?(scopes)

      application.update_columns(scopes: (scopes - [NEW_SCOPE]).join(" "), updated_at: Time.current)
    end
  end

  private
    def old_default_scopes?(scopes)
      (scopes - OLD_PUBLIC_SCOPES).empty? && (OLD_PUBLIC_SCOPES - scopes).empty?
    end

    def new_default_scopes?(scopes)
      old_default_scopes?(scopes - [NEW_SCOPE])
    end

    def oauth_applications
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_applications"
      end
    end
end
