# frozen_string_literal: true

# The CLI's OAuth app mints tokens from the scopes the CLI requests. Most public
# endpoints accept the broad legacy `account` scope as a fallback, but a token
# authorized for a team store never carries `account` — it keeps only what the
# requested scopes intersect with the member's role — so the CLI now asks for the
# scopes its commands need by name. `edit_emails` guards the emails, workflows and
# marketing commands, so the application has to carry it before the CLI can
# request it. Adding the scope to the app lets newly minted tokens carry it;
# existing tokens are unchanged and need a re-login (antiwork/gumroad-private#4376).
class AddEditEmailsScopeToGumroadCliOauthApplication < ActiveRecord::Migration[7.1]
  CLI_CLIENT_ID = "oljO5HmcOWvCZ5wbitpXPXk3u0LjAb5GdAEBBU5hwKA"
  SCOPE = "edit_emails"

  def up
    app = oauth_applications.find_by(uid: CLI_CLIENT_ID)

    if app.nil?
      message = "Gumroad CLI OAuth application #{CLI_CLIENT_ID} was not found"
      raise ActiveRecord::RecordNotFound, message if Rails.env.production?

      say "#{message}; skipping production-only scope update"
      return
    end

    scopes = app.scopes.to_s.split
    return if scopes.include?(SCOPE)

    app.update!(scopes: scopes.push(SCOPE).join(" "))
  end

  # Rolling back removes edit_emails unconditionally, even if the scope was
  # already present before this migration ran (in which case `up` was a no-op).
  # That's deliberate: `down` restores the declared pre-migration state ("CLI
  # app does not carry edit_emails") rather than tracking whether `up` made a
  # change. The production app verifiably lacks the scope today, so in practice
  # the two are equivalent.
  #
  # Removing the scope from the application alone is not enough: endpoint
  # authorization checks the scopes stored on the access token, and Gumroad's
  # tokens never expire. Any token minted while this migration was deployed
  # would keep edit_emails forever, and pending/approved device authorizations
  # could still mint such a token later. So `down` also strips the scope from
  # every access token, access grant, and device authorization issued for this
  # application (same approach as
  # RevokeBackfilledEditEmailsScopeFromDefaultOauthApplications).
  #
  # Concurrency: MySQL does not wrap migrations in a transaction, so we open
  # one explicitly and take the same oauth_applications row lock used when
  # authorization sources are created, refresh tokens are exchanged, direct
  # application credentials are generated, and device codes are polled. Holding
  # that lock for the whole cleanup prevents a request that saw the old scopes
  # from inserting a new issuance source after its sweep. Ordering also matters:
  # issuance sources (device authorizations, then access grants) are cleaned
  # BEFORE access tokens, and tokens are swept LAST — so any token minted just
  # before we acquired the lock is still caught by the final token sweep instead
  # of slipping in after it.
  def down
    oauth_applications.transaction do
      app = oauth_applications.lock.find_by(uid: CLI_CLIENT_ID)
      next if app.nil?

      scopes = app.scopes.to_s.split - [SCOPE]
      app.update!(scopes: scopes.join(" "), updated_at: Time.current)

      revoke_scope_from_device_authorizations(app.id)
      revoke_scope(oauth_access_grants, app.id, application_id_column: :application_id)
      revoke_scope(oauth_access_tokens, app.id, application_id_column: :application_id)
    end
  end

  private
    # Locking reads (FOR UPDATE) so each batch sees the latest committed rows
    # rather than this transaction's REPEATABLE READ snapshot — a token or
    # grant committed by a concurrent request just before we took the
    # application lock must still be visible to the sweep.
    def revoke_scope(records, application_id, application_id_column:)
      records.where(application_id_column => application_id).where("scopes LIKE ?", "%#{SCOPE}%").lock.find_each do |record|
        scopes = record.scopes.to_s.split
        next unless scopes.include?(SCOPE)

        record.update_columns(scopes: (scopes - [SCOPE]).join(" "))
      end
    end

    # A device authorization whose only scope was edit_emails has nothing left
    # to grant, so it is deleted rather than left as an empty-scope row.
    def revoke_scope_from_device_authorizations(application_id)
      oauth_device_authorizations.where(oauth_application_id: application_id).where("scopes LIKE ?", "%#{SCOPE}%").lock.find_each do |authorization|
        scopes = authorization.scopes.to_s.split
        next unless scopes.include?(SCOPE)

        remaining_scopes = scopes - [SCOPE]
        if remaining_scopes.empty?
          authorization.delete
        else
          authorization.update_columns(scopes: remaining_scopes.join(" "), updated_at: Time.current)
        end
      end
    end

    def oauth_applications
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_applications"
      end
    end

    def oauth_access_tokens
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_access_tokens"
      end
    end

    def oauth_access_grants
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_access_grants"
      end
    end

    def oauth_device_authorizations
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_device_authorizations"
      end
    end
end
