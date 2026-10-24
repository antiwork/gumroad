# frozen_string_literal: true

# Ends a LowBalanceFraudCheck probation once the seller's balance has recovered, restoring the
# risk state that probation replaced. The automatic balance check and the audited admin action
# both decide here, under the same row locks, so neither can act on a copy the other made stale.
class LowBalanceProbationRecovery
  PROBATION_AUTHOR_NAME = "LowBalanceFraudCheck"
  RECOVERY_THRESHOLD_CENTS = 100_00
  RESTORABLE_STATES = %w[compliant not_reviewed].freeze
  # Any of these after the probation comment means someone has decided about the account since.
  DECISION_COMMENT_TYPES = (Comment::RISK_STATE_COMMENT_TYPES + [Comment::COMMENT_TYPE_FLAG_NOTE, Comment::COMMENT_TYPE_SUSPENSION_NOTE]).freeze
  # A probation's version and comment come from one transaction; a wider gap is not one transition.
  MAX_TRANSITION_GAP = 5.minutes
  # Reviewed snapshots name this digest, so a snapshot taken under other rules cannot be executed.
  RULES_DIGEST = Digest::SHA256.file(__FILE__).hexdigest

  HISTORY_REASONS = %i[
    missing_probation_history
    probation_history_ambiguous
    probation_transition_not_bound
    unsupported_prior_state
  ].freeze

  # `probation_comment` is the LowBalanceFraudCheck comment the state change is bound to;
  # `latest_probation_comment` is the newest one, a later re-assertion when the check fired again.
  Evaluation = Data.define(:user, :reason, :probation_comment, :latest_probation_comment, :transition_version,
                           :provenance, :prior_state, :unpaid_balance_cents, :recovery_comment) do
    def eligible? = reason.nil?
    def target_state = (prior_state if eligible?)

    def snapshot_facts
      {
        "user_id" => user.id,
        "user_external_id" => user.external_id,
        "probation_comment_id" => probation_comment&.id,
        "latest_probation_comment_id" => latest_probation_comment&.id,
        "transition_version_id" => transition_version&.id,
        "prior_state" => prior_state,
        "target_state" => target_state,
      }
    end

    def as_json(*)
      {
        user_id: user.external_id,
        eligible: eligible?,
        reason: reason&.to_s,
        user_risk_state: user.user_risk_state,
        probation_comment_id: probation_comment&.id,
        probation_comment_created_at: probation_comment&.created_at&.iso8601,
        latest_probation_comment_id: latest_probation_comment&.id,
        transition_version_id: transition_version&.id,
        transition_version_created_at: transition_version&.created_at&.iso8601(6),
        provenance: provenance&.to_s,
        prior_state:,
        target_state:,
        unpaid_balance_cents:,
        recovery_comment_id: recovery_comment&.id,
      }
    end
  end

  # `rolled_back` is only ever true when the account's transaction raised before committing.
  Outcome = Data.define(:user, :status, :reason, :evaluation, :readback, :error_class, :rolled_back) do
    def as_json(*)
      {
        user_id: user.external_id,
        outcome: status.to_s,
        reason: reason&.to_s,
        target_state: evaluation&.target_state || evaluation&.recovery_comment&.comment_type,
        probation_comment_id: evaluation&.probation_comment&.id,
        latest_probation_comment_id: evaluation&.latest_probation_comment&.id,
        recovered_by: (evaluation&.recovery_comment && (evaluation.recovery_comment.author_id ? "admin" : "automatic")),
        rolled_back:,
        error_class:,
        readback:,
      }
    end
  end

  def self.idempotency_key(probation_comment) = "low_balance_probation_recovery:#{probation_comment.id}"

  attr_reader :user

  def initialize(user)
    @user = user
  end

  # Read-only: no transaction and no locks, so the result is only as current as the moment it ran.
  def evaluate
    on_primary { evaluate_rules }
  end

  # Runs on every qualifying balance increase, so an account that cannot be recovered is turned
  # away by the unlocked read and a log line; only an eligible one takes the locks and re-checks.
  def recover_automatically!
    precheck = evaluate
    unless precheck.eligible?
      if HISTORY_REASONS.include?(precheck.reason)
        Rails.logger.warn("LowBalanceFraudCheck recovery skipped: #{precheck.reason} (user_id=#{user.id})")
      end
      return precheck
    end

    with_locked_evaluation do |evaluation|
      transition!(evaluation, author_name: PROBATION_AUTHOR_NAME, content: automatic_content) if evaluation.eligible?
      evaluation
    end
  end

  # `expected` is the reviewed snapshot's facts for this account. Anything that moved since the
  # review, or any exclusion that now applies, ends without a write. Never raises: an exception
  # after the transition was written may have come from COMMIT or an after-commit callback, so
  # the outcome then comes from a fresh read of the row, not from the exception.
  def recover_for_admin!(actor:, request_id:, expected:)
    evaluation = nil
    written = false
    status, reason = with_locked_evaluation do |locked|
      evaluation = locked
      decision = admin_decision(locked, expected)
      if decision.first == :recovered
        transition!(locked, author_id: actor.id, content: admin_content(actor, request_id))
        written = true
      end
      decision
    end
    return outcome(status, reason, evaluation) unless status == :recovered

    confirm_recovery(evaluation, actor, error: nil)
  rescue StandardError => e
    report(e)
    written ? confirm_recovery(evaluation, actor, error: e) : outcome(:error, :rolled_back, evaluation, error: e, rolled_back: true)
  end

  private
    def on_primary(&block)
      ApplicationRecord.connected_to(role: :writing) { ActiveRecord::Base.uncached(&block) }
    end

    # Lock order is users, then balances, then comments. Payouts take users before balances,
    # balance writers never lock users, and every risk transition locks the users row first.
    def with_locked_evaluation
      on_primary do
        User.transaction do
          user.lock!
          yield evaluate_rules(lock: true)
        end
      end
    end

    def admin_decision(evaluation, expected)
      if evaluation.reason == :already_recovered then [:already_recovered, nil]
      elsif !evaluation.eligible? then [:skipped, evaluation.reason]
      elsif evaluation.snapshot_facts != expected then [:stale_snapshot, :facts_changed_since_review]
      else [:recovered, nil]
      end
    end

    def outcome(status, reason, evaluation, readback: nil, error: nil, rolled_back: nil)
      Outcome.new(user:, status:, reason:, evaluation:, readback:, error_class: error&.class&.name, rolled_back:)
    end

    def evaluate_rules(lock: false)
      balances = unpaid_balances(lock:)
      comments = user_comments(lock:)
      build = ->(reason, **facts) { evaluation(reason, balances:, **facts) }

      return build.(:account_deleted) if user.deleted?

      latest = comments.select { low_balance_probation_comment?(_1) }.max_by(&:id)
      return build.(:no_low_balance_probation) if latest.nil?

      decisions = comments.select { DECISION_COMMENT_TYPES.include?(_1.comment_type) }.sort_by(&:id)
      later_decisions = decisions.select { _1.id > latest.id }
      chain = reassertion_chain(decisions, latest)
      facts = { latest_probation_comment: latest }
      recovery_comment = later_decisions.find { recovery_comment_for?(_1, chain) }
      if recovery_comment && recovery_comment == later_decisions.last && user.user_risk_state == recovery_comment.comment_type
        return build.(:already_recovered, **facts, recovery_comment:)
      end

      return build.(:suspended, **facts) if user.suspended?
      return build.(:flagged, **facts) if user.flagged?
      return build.(:not_on_probation, **facts) unless user.on_probation?
      return build.(:probation_comment_deleted, **facts) if chain.any?(&:deleted?)
      return build.(:newer_risk_decision, **facts) if later_decisions.any?

      reason, version, provenance, bound_comment = bind_probation_transition(chain, comments)
      return build.(reason, **facts, transition_version: version, provenance:) if reason

      prior_state = risk_state_change(version).first
      history = { **facts, probation_comment: bound_comment, transition_version: version, provenance:, prior_state: }
      return build.(:unsupported_prior_state, **history) unless RESTORABLE_STATES.include?(prior_state)
      return build.(:noncanonical_balance, **history) if balances.any? { _1.currency != Currency::USD }
      return build.(:insufficient_balance, **history) if balances.sum(&:amount_cents) < RECOVERY_THRESHOLD_CENTS

      build.(nil, **history)
    end

    def evaluation(reason, balances:, probation_comment: nil, latest_probation_comment: nil, transition_version: nil,
                   provenance: nil, prior_state: nil, recovery_comment: nil)
      Evaluation.new(user:, reason:, probation_comment:, latest_probation_comment:, transition_version:, provenance:,
                     prior_state:, unpaid_balance_cents: balances.sum(&:amount_cents), recovery_comment:)
    end

    def low_balance_probation_comment?(comment)
      comment.comment_type == Comment::COMMENT_TYPE_ON_PROBATION && comment.author_name == PROBATION_AUTHOR_NAME && comment.author_id.nil?
    end

    # The check probates again whenever its 2-month wait has passed, even on an account its own
    # probation still holds. Those re-assertions change no state, so the run of LowBalanceFraudCheck
    # comments ending at the newest one, with no other decision between them, is one probation.
    def reassertion_chain(decisions, latest)
      decisions.take_while { _1.id <= latest.id }.reverse.take_while { low_balance_probation_comment?(_1) }.reverse
    end

    # Filtered in Ruby on purpose: a locking read through the comment-type index would lock that
    # type's range for every user, while this index confines the locks to this account.
    def user_comments(lock:)
      scope = Comment.where(commentable_type: "User", commentable_id: user.id)
      scope = scope.lock("FOR SHARE") if lock
      scope.select(:id, :comment_type, :author_id, :author_name, :idempotency_key, :created_at, :deleted_at).to_a
    end

    def unpaid_balances(lock:)
      scope = Balance.where(user_id: user.id, state: "unpaid")
      scope = scope.lock("FOR SHARE") if lock
      scope.select(:id, :currency, :amount_cents).to_a
    end

    def recovery_comment_for?(comment, chain)
      return false unless RESTORABLE_STATES.include?(comment.comment_type)

      chain.any? { comment.idempotency_key == self.class.idempotency_key(_1) } ||
        (comment.idempotency_key.nil? && comment.author_name == PROBATION_AUTHOR_NAME && comment.author_id.nil?)
    end

    # The state change must be bound to one comment of the chain; later ones are re-assertions.
    def bind_probation_transition(chain, comments)
      user_versions = PaperTrail::Version.where(item_type: "User", item_id: user.id)
      version = user_versions
        .where("JSON_CONTAINS_PATH(CAST(object_changes AS JSON), 'one', '$.user_risk_state')")
        .order(id: :desc)
        .first
      return [:missing_probation_history] if version.nil?
      return [:probation_history_ambiguous, version] unless risk_state_change(version).last == "on_probation"
      return [:probation_history_ambiguous, version] if user_versions.where("id > ?", version.id).where(object_changes: nil).exists?

      failure = nil
      chain.each do |comment|
        reason, provenance = bind_comment(version, comment, comments, user_versions)
        return [nil, version, provenance, comment] if reason.nil?

        failure ||= reason
      end
      [failure, version]
    end

    # Nothing links a comment to its version, so bind them by what one transition writes under the
    # users-row lock: the state change's version, then its own comment, with nothing between. An
    # unreadable history is excluded, never guessed.
    def bind_comment(version, probation_comment, comments, user_versions)
      other_decisions = comments.select { _1.id != probation_comment.id && DECISION_COMMENT_TYPES.include?(_1.comment_type) }
      comment_version = PaperTrail::Version.where(item_type: "Comment", item_id: probation_comment.id, event: "create").order(:id).first

      if comment_version
        return [:probation_transition_not_bound] unless comment_version.id > version.id
        return [:probation_transition_not_bound] if user_versions.where(id: (version.id + 1)...comment_version.id).exists?
        if other_decisions.any? && PaperTrail::Version.where(item_type: "Comment", item_id: other_decisions.map(&:id), event: "create")
                                                      .where(id: (version.id + 1)...comment_version.id).exists?
          return [:probation_transition_not_bound]
        end
        return [:probation_history_ambiguous] if comment_version.created_at - version.created_at > MAX_TRANSITION_GAP

        [nil, :comment_version]
      else
        # comments.created_at has one-second precision, so a decision written in the same second
        # as the version cannot be ordered against it.
        version_second = version.created_at.change(usec: 0)
        return [:probation_history_ambiguous] unless probation_comment.created_at.between?(version_second, version.created_at + MAX_TRANSITION_GAP)
        return [:probation_history_ambiguous] if other_decisions.any? { _1.id < probation_comment.id && _1.created_at >= version_second }

        [nil, :timestamp]
      end
    end

    def risk_state_change(version)
      Array(JSON.parse(version.object_changes.to_s)["user_risk_state"])
    rescue JSON::ParserError
      []
    end

    def transition!(evaluation, content:, author_id: nil, author_name: nil)
      params = { author_id:, author_name:, content:, idempotency_key: self.class.idempotency_key(evaluation.probation_comment) }.compact
      case evaluation.target_state
      when "compliant" then user.mark_compliant!(**params)
      when "not_reviewed" then user.mark_not_reviewed!(**params)
      else raise ArgumentError, "no restorable target state for user #{user.id}"
      end
    end

    # `error` is an exception raised after the transition was written. Without one the transaction
    # committed, so only the readback is in question. Side effects are never replayed from here.
    def confirm_recovery(evaluation, actor, error:)
      readback = committed_state(evaluation)
      target_state = evaluation.target_state
      committed = readback[:recovery_comment_id].present?
      confirmed = readback[:user_risk_state] == target_state && readback[:recovery_comment_type] == target_state &&
                  readback[:recovery_comment_author_id] == actor.id

      if error.nil? && confirmed
        outcome(:recovered, nil, evaluation, readback:)
      elsif error && !committed
        outcome(:error, :rolled_back, evaluation, readback:, error:, rolled_back: true)
      else
        outcome(:committed_unconfirmed, error ? :post_commit_step_failed : :committed_readback_mismatch, evaluation,
                readback:, error:, rolled_back: false)
      end
    rescue StandardError => readback_error
      report(readback_error)
      if error
        outcome(:unknown, :commit_state_unreadable, evaluation, error:)
      else
        outcome(:committed_unconfirmed, :readback_failed, evaluation, error: readback_error, rolled_back: false)
      end
    end

    def committed_state(evaluation)
      on_primary do
        risk_state, flags = User.where(id: user.id).pick(:user_risk_state, :flags)
        comment_id, comment_type, author_id = Comment
          .where(commentable_type: "User", commentable_id: user.id, idempotency_key: self.class.idempotency_key(evaluation.probation_comment))
          .pick(:id, :comment_type, :author_id)
        {
          user_risk_state: risk_state,
          refunds_disabled: (flags.to_i & User.flag_mapping["flags"][:refunds_disabled]) != 0,
          recovery_comment_id: comment_id,
          recovery_comment_type: comment_type,
          recovery_comment_author_id: author_id,
        }
      end
    end

    # A notifier failure must not replace the account's outcome.
    def report(error)
      ErrorNotifier.notify(error)
    rescue StandardError => notify_error
      Rails.logger.error("LowBalanceProbationRecovery could not report #{error.class}: #{notify_error.class}")
    end

    def automatic_content
      "Probation removed automatically on #{Time.current.to_fs(:formatted_date_full_month)} as balance has recovered to #{threshold_text}"
    end

    def admin_content(actor, request_id)
      "Probation removed on #{Time.current.to_fs(:formatted_date_full_month)} by #{actor.name_or_username} as the LowBalanceFraudCheck " \
        "probation's balance has recovered to #{threshold_text} (admin API request #{request_id})"
    end

    def threshold_text = MoneyFormatter.format(RECOVERY_THRESHOLD_CENTS, :usd, no_cents_if_whole: true, symbol: true)
end
