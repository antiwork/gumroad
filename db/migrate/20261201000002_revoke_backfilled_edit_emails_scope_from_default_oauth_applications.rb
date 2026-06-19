# frozen_string_literal: true

class RevokeBackfilledEditEmailsScopeFromDefaultOauthApplications < ActiveRecord::Migration[7.1]
  OLD_PUBLIC_SCOPES = %w[edit_products view_sales mark_sales_as_shipped edit_sales revenue_share ifttt view_profile view_payouts view_tax_data account].freeze
  NEW_SCOPE = "edit_emails"
  # First production tag containing PR #5503 and not this fix:
  # production-2ebe108daf96/2026-06-19-14-35-41.
  EDIT_EMAILS_SCOPE_DEPLOYED_AT = Time.utc(2026, 6, 19, 14, 35, 41)

  def up
    application_ids = candidate_application_ids
    updated_at = Time.current
    oauth_applications.where(id: application_ids).update_all(scopes: OLD_PUBLIC_SCOPES.join(" "), updated_at:) if application_ids.any?

    application_ids_without_edit_emails = oauth_applications.where.not("scopes LIKE ?", "%#{NEW_SCOPE}%").select(:id)
    revoke_edit_emails_scope(oauth_access_grants, application_ids_without_edit_emails, application_id_column: :application_id)
    revoke_edit_emails_scope(oauth_access_tokens, application_ids_without_edit_emails, application_id_column: :application_id)
    revoke_edit_emails_scope_from_device_authorizations(application_ids_without_edit_emails, updated_at:)
  end

  def down
  end

  private
    def old_default_scopes?(scopes)
      (scopes - OLD_PUBLIC_SCOPES).empty? && (OLD_PUBLIC_SCOPES - scopes).empty?
    end

    def backfilled_default_scopes?(scopes)
      old_default_scopes?(scopes - [NEW_SCOPE]) && scopes.include?(NEW_SCOPE)
    end

    def revoke_edit_emails_scope(records, application_ids, application_id_column:, updated_at: nil)
      records.where(application_id_column => application_ids).where("scopes LIKE ?", "%#{NEW_SCOPE}%").find_each do |record|
        scopes = record.scopes.to_s.split
        next unless scopes.include?(NEW_SCOPE)

        attributes = { scopes: (scopes - [NEW_SCOPE]).join(" ") }
        attributes[:updated_at] = updated_at if updated_at
        record.update_columns(attributes)
      end
    end

    def revoke_edit_emails_scope_from_device_authorizations(application_ids, updated_at:)
      oauth_device_authorizations.where(oauth_application_id: application_ids).where("scopes LIKE ?", "%#{NEW_SCOPE}%").find_each do |authorization|
        scopes = authorization.scopes.to_s.split
        next unless scopes.include?(NEW_SCOPE)

        scopes_without_edit_emails = scopes - [NEW_SCOPE]
        if scopes_without_edit_emails.empty?
          authorization.delete
        else
          authorization.update_columns(scopes: scopes_without_edit_emails.join(" "), updated_at:)
        end
      end
    end

    def candidate_application_ids
      ids = []
      oauth_applications.find_each do |application|
        scopes = application.scopes.to_s.split
        next unless application.created_at < EDIT_EMAILS_SCOPE_DEPLOYED_AT
        next unless scopes.empty? || old_default_scopes?(scopes) || backfilled_default_scopes?(scopes)

        ids << application.id
      end
      ids
    end

    def oauth_applications
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_applications"
      end
    end

    def oauth_access_grants
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_access_grants"
      end
    end

    def oauth_access_tokens
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_access_tokens"
      end
    end

    def oauth_device_authorizations
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_device_authorizations"
      end
    end
end
