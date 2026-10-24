# frozen_string_literal: true

# Ends LowBalanceFraudCheck probations whose balance has recovered, for an explicit list of
# accounts. `preview` changes no account state and returns a signed snapshot of the eligible ones;
# `execute` acts only on accounts from that snapshot whose facts are unchanged when re-checked.
class Api::Internal::Admin::LowBalanceProbationRecoveriesController < Api::Internal::Admin::BaseController
  MAX_ACCOUNTS = 25
  ACCOUNT_AUDIT_ACTION = "low_balance_probation_recoveries.execute_account"
  # A write may have happened, or did not happen in a way nobody has looked at: stop the run.
  STOPPING_OUTCOMES = %w[error committed_unconfirmed unknown].freeze

  # Restoring a risk state needs an attributable actor, not the shared legacy token.
  before_action :require_per_actor_token!

  def preview
    record_admin_write(action: "low_balance_probation_recoveries.preview") do
      external_ids = requested_external_ids
      next unless external_ids

      users = ApplicationRecord.connected_to(role: :writing) { User.where(external_id: external_ids).index_by(&:external_id) }
      evaluations = external_ids.index_with { users[_1] && LowBalanceProbationRecovery.new(users[_1]).evaluate }
      eligible = evaluations.values.compact.select(&:eligible?)
      snapshot, expires_at = LowBalanceProbationRecovery::Snapshot.issue(eligible, actor: Current.admin_actor, request_id: request.request_id) if eligible.any?

      render json: {
        success: true,
        request_id: request.request_id,
        actor: serialize_admin_actor(Current.admin_actor),
        rules_digest: LowBalanceProbationRecovery::RULES_DIGEST,
        accounts: evaluations.map { |external_id, evaluation| evaluation&.as_json || { user_id: external_id, eligible: false, reason: "user_not_found" } },
        eligible_user_ids: eligible.map { _1.user.external_id },
        snapshot:,
        snapshot_expires_at: expires_at&.iso8601,
      }
    end
  end

  def execute
    record_admin_write(action: "low_balance_probation_recoveries.execute") do
      external_ids = requested_external_ids
      next unless external_ids

      snapshot = LowBalanceProbationRecovery::Snapshot.verify!(params[:snapshot], actor: Current.admin_actor)
      unreviewed = external_ids - snapshot.accounts.keys
      if unreviewed.any?
        next render json: { success: false, message: "user_ids are not eligible in the reviewed snapshot: #{unreviewed.join(", ")}" }, status: :unprocessable_entity
      end

      results = execute_serially(external_ids, snapshot)
      render json: {
        success: true,
        request_id: request.request_id,
        actor: serialize_admin_actor(Current.admin_actor),
        snapshot_request_id: snapshot.request_id,
        snapshot_actor_id: User.find_by(id: snapshot.actor_id)&.external_id,
        results:,
        counts: results.map { _1[:outcome] }.tally,
      }
    rescue LowBalanceProbationRecovery::Snapshot::Invalid => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
  end

  private
    def requested_external_ids
      raw = params[:user_ids]
      external_ids = raw.is_a?(Array) ? raw.map { _1.to_s.strip } : []
      message =
        if external_ids.empty? || external_ids.any?(&:blank?)
          "user_ids is required"
        elsif external_ids.size > MAX_ACCOUNTS
          "at most #{MAX_ACCOUNTS} user_ids per request"
        elsif external_ids.uniq.size != external_ids.size
          "user_ids must not repeat"
        end
      return external_ids unless message

      render json: { success: false, message: }, status: :bad_request
      nil
    end

    # One transaction per account, in request order, each leaving its own audit row with the
    # account as target. Anything other than a clean or no-write outcome stops the run.
    def execute_serially(external_ids, snapshot)
      users = ApplicationRecord.connected_to(role: :writing) do
        User.where(id: external_ids.map { snapshot.accounts.fetch(_1)["user_id"] }).index_by(&:id)
      end
      stopped = false
      external_ids.map do |external_id|
        user = users[snapshot.accounts.fetch(external_id)["user_id"]]
        result = stopped ? { user_id: external_id, outcome: "not_attempted" } : execute_account(external_id, user, snapshot)
        stopped ||= STOPPING_OUTCOMES.include?(result[:outcome])
        write_account_audit_log(user, result, snapshot)
        result
      end
    end

    def execute_account(external_id, user, snapshot)
      return { user_id: external_id, outcome: "stale_snapshot", reason: "user_changed_since_review" } if user&.external_id != external_id

      LowBalanceProbationRecovery.new(user)
        .recover_for_admin!(actor: Current.admin_actor, request_id: request.request_id, expected: snapshot.accounts.fetch(external_id))
        .as_json
    end

    def write_account_audit_log(user, result, snapshot)
      return if Current.admin_actor.blank? || Current.admin_token.blank?

      attributes = {
        actor_user_id: Current.admin_actor.id,
        admin_api_token_id: Current.admin_token.id,
        action: ACCOUNT_AUDIT_ACTION,
        target_type: admin_audit_target_type(user),
        target_id: user&.id,
        target_external_id: admin_audit_target_external_id(user),
        route: admin_audit_route,
        http_method: request.request_method,
        params_snapshot: result.merge(snapshot_request_id: snapshot.request_id),
        request_id: request.request_id,
        error_class: result[:error_class],
        created_at: Time.current,
      }
      AdminApiAuditLog.create!(attributes)
    rescue StandardError => e
      handle_admin_audit_log_failure(e, attributes)
    end
end
