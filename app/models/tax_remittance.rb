# frozen_string_literal: true

# System of record for international tax remittances — the quarterly VAT/GST
# payments Gumroad sends to foreign tax authorities (Irish Revenue for EU OSS,
# HMRC, ATO, etc.) from the Wise treasury account. Built for
# gumroad-private#1100: replaces "someone paid it from the Wise dashboard and
# reconciled it into QBO by hand" with a table every phase of the automation
# (read-only sync, JE drafting, approval-gated API payments) reads and writes.
#
# Lifecycle: draft → pending_approval → funded → sent → completed. A draft is
# the system's proposed payment for a period (amount computed from collected
# tax); a human approves it before any money moves. `failed` and `cancelled`
# are terminal — a retry is a NEW row for the same (authority, period) with
# the next attempt number (see #build_retry), so the failed attempt's history
# is preserved. Backfilled historical rows go straight to completed.
class TaxRemittance < ApplicationRecord
  include ExternalId

  # Raised when a reviewer submits a draft for approval but the amount they
  # were looking at is no longer the amount on the row — the staging service
  # recomputed it in between (late sales, refunds, chargebacks land while a
  # quarter is still settling). Callers should show the reviewer the new
  # amount and make them submit again rather than letting an unreviewed
  # number enter the approval flow.
  class AmountChangedSinceReview < StandardError; end

  # Raised when a row is submitted for approval without a target-currency
  # amount. An authority is paid in its own currency, so a row whose
  # target_amount_cents is still nil describes only half a payment: the
  # approver would be signing off on a USD estimate while the amount that
  # actually leaves the account is decided later by whoever funds it.
  class TargetAmountMissing < StandardError; end

  RAILS = %w[wise stripe_global_payouts mercury].freeze
  STATUSES = %w[draft pending_approval funded sent completed failed cancelled].freeze
  TERMINAL_STATUSES = %w[completed failed cancelled].freeze
  # Terminal statuses that a retry attempt may follow. `completed` is absent
  # on purpose: the money arrived, there is nothing to retry.
  RETRYABLE_STATUSES = %w[failed cancelled].freeze

  # Statuses where a human has already approved (or is approving) specific
  # numbers, but no money has moved yet. The approved figures are frozen here
  # for the same reason they are frozen once sent: they are what somebody
  # signed off on. Changing them requires revoking the approval first (back to
  # draft) so the row is reviewed and submitted again — see #revoke_approval!.
  APPROVAL_BOUND_STATUSES = %w[pending_approval funded].freeze
  # The figures an approval binds: the reviewed USD estimate and the
  # target-currency amount that will actually be sent.
  APPROVAL_BOUND_AMOUNTS = %w[usd_amount_cents target_amount_cents].freeze

  # Statuses from which the row describes a real payment: `sent` means money
  # has already left the account, so even though the row isn't terminal yet,
  # its payment facts are just as much a matter of record as a completed one.
  PAYMENT_LOCKED_STATUSES = (["sent"] + TERMINAL_STATUSES).freeze
  # The only places a `sent` remittance may go: it either lands (completed),
  # bounces (failed), or the in-flight transfer is recalled (cancelled). It
  # must never regress to draft/pending_approval/funded — that would make an
  # already-sent payment look actionable again.
  SENT_OUTCOME_STATUSES = %w[sent completed failed cancelled].freeze

  # Once money has moved (`sent` or any terminal state), the payment identity
  # is frozen — these fields describe WHAT was (or wasn't) paid and can never
  # be rewritten. Status is handled separately: frozen entirely on terminal
  # rows, restricted to SENT_OUTCOME_STATUSES on sent rows.
  FROZEN_WHEN_LOCKED = %w[authority jurisdiction period currency usd_amount_cents rail attempt paid_at].freeze
  # Reconciliation fields the Wise statement sync fills in after the fact:
  # they may go from nil to a value on a locked row (enrichment), but once
  # set they are frozen too — changing a recorded amount or transfer ID on a
  # sent/completed payment would falsify the record.
  ENRICHABLE_WHEN_LOCKED = %w[target_amount_cents transfer_id].freeze
  # qbo_journal_entry_ref and notes stay freely writable: they are annotations
  # about the payment, not the payment itself.

  # The recurring authorities paid from the Wise treasury today, keyed by the
  # stable authority slug used in `authority`. `jurisdiction` is the ISO
  # country code, except EU_OSS: the Irish Revenue one-stop-shop filing that
  # remits VAT for all EU member states in a single payment.
  KNOWN_AUTHORITIES = {
    "Irish Revenue (EU VAT OSS)" => { jurisdiction: "EU_OSS", currency: "EUR" },
    "HMRC" => { jurisdiction: "GB", currency: "GBP" },
    "Australian Taxation Office" => { jurisdiction: "AU", currency: "AUD" },
    "Norwegian Tax Administration" => { jurisdiction: "NO", currency: "NOK" },
    "Inland Revenue Department (NZ)" => { jurisdiction: "NZ", currency: "NZD" },
    "Eidgenössisches Finanzdepartement (Swiss VAT)" => { jurisdiction: "CH", currency: "CHF" },
    "IRAS Singapore" => { jurisdiction: "SG", currency: "SGD" },
  }.freeze

  PERIOD_FORMAT = /\A\d{4}-Q[1-4]\z/

  validates :authority, presence: true
  validates :jurisdiction, presence: true
  validates :period, presence: true, format: { with: PERIOD_FORMAT, message: "must look like 2026-Q1" }
  validates :attempt, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :authority, uniqueness: { scope: [:period, :attempt] }
  validates :currency, presence: true, length: { is: 3 }
  validates :usd_amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :target_amount_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :rail, presence: true, inclusion: { in: RAILS }
  # A rail-side payment (Wise transfer, Stripe payout, Mercury transaction)
  # must map to at most one remittance — two rows claiming the same transfer
  # would double-count one real payment during reconciliation. Backed by a
  # unique index on (rail, transfer_id); nil is fine (payment not made yet).
  validates :transfer_id, uniqueness: { scope: :rail }, allow_nil: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :paid_at, presence: true, if: -> { status.in?(%w[sent completed]) }

  scope :for_period, ->(period) { where(period:) }
  scope :in_progress, -> { where.not(status: TERMINAL_STATUSES) }
  scope :completed, -> { where(status: "completed") }
  scope :awaiting_approval, -> { where(status: "pending_approval") }

  validate :payment_locked_rows_immutable, on: :update
  validate :approved_amounts_immutable, on: :update
  validate :single_live_attempt_per_filing

  def self.period_for(date)
    "#{date.year}-Q#{(date.month - 1) / 3 + 1}"
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  # Records the target-currency amount that will actually be sent to the
  # authority. Only allowed while the row is still a draft: from
  # pending_approval onward the target amount is part of what an approver
  # signed off on, so it is bound (see #approved_amounts_immutable) and
  # changing it means revoking the approval and having the numbers reviewed
  # again.
  def record_target_amount!(cents)
    with_lock do
      raise ArgumentError, "can only set a target amount on a draft (status is #{status})" unless status == "draft"

      update!(target_amount_cents: cents)
    end

    self
  end

  # Returns an approved (or approval-pending) row to draft so its amounts can
  # be corrected. The approval is deliberately discarded: whoever changes the
  # numbers has to submit them for approval again, so nothing is ever funded
  # on figures no human reviewed. Refused once money has moved — a sent or
  # terminal row is a record of a real payment, not a proposal.
  def revoke_approval!
    with_lock do
      unless status.in?(APPROVAL_BOUND_STATUSES)
        raise ArgumentError, "can only revoke approval on a pending_approval or funded remittance (status is #{status})"
      end

      update!(status: "draft")
    end

    self
  end

  # Moves a draft to pending_approval, but only if BOTH amounts are still the
  # ones the reviewer was shown: the USD estimate and the target-currency
  # amount that will actually be sent.
  #
  # Why the check exists: the staging service (TaxRemittances::StageQuarterlyDrafts)
  # is meant to be re-run while a quarter is still settling, and it rewrites an
  # untouched draft's amount when the liability moves. So between the moment a
  # reviewer loads a draft and the moment they submit it, the number on the row
  # can legitimately change. Submitting without re-checking would carry an
  # amount into the approval flow that nobody reviewed — the reviewer approves
  # "the row", and the row now says something else.
  #
  # `reviewed_amount_cents` and `reviewed_target_amount_cents` are the amounts
  # the reviewer actually saw. They are
  # compared inside the same SELECT ... FOR UPDATE + UPDATE transaction the
  # staging refresh uses, so the two orderings both end safely: if the refresh
  # commits first we raise here and the reviewer re-reads; if this commits
  # first the refresh sees a non-draft row and backs off.
  #
  # A row with no target_amount_cents cannot enter approval at all: the
  # approver would be binding a USD estimate while leaving the amount that
  # actually leaves the account for someone downstream to pick. Set it with
  # #record_target_amount! first.
  #
  # Raises AmountChangedSinceReview if it moved, ArgumentError if the row is
  # not a draft, TargetAmountMissing if no target amount is recorded.
  def submit_for_approval!(reviewed_amount_cents:, reviewed_target_amount_cents:)
    with_lock do
      raise ArgumentError, "can only submit a draft for approval (status is #{status})" unless status == "draft"

      raise TargetAmountMissing, "no target_amount_cents recorded for #{authority} #{period}" if target_amount_cents.nil?

      if usd_amount_cents != reviewed_amount_cents
        raise AmountChangedSinceReview,
              "amount is now #{usd_amount_cents} cents, not the #{reviewed_amount_cents} reviewed"
      end

      if target_amount_cents != reviewed_target_amount_cents
        raise AmountChangedSinceReview,
              "target amount is now #{target_amount_cents} cents, not the #{reviewed_target_amount_cents} reviewed"
      end

      update!(status: "pending_approval")
    end

    self
  end

  # Builds (does not save) the next attempt for a failed or cancelled
  # remittance: same filing identity, attempt number incremented, payment
  # state reset to a fresh draft. Raises if this attempt isn't retryable —
  # completed payments have nothing to retry, and retrying a live attempt
  # would create two concurrent payments for one filing.
  #
  # The next attempt number comes from the filing's current MAXIMUM attempt,
  # not from this row's own number: if attempt 1 and attempt 2 both failed,
  # retrying from the older attempt 1 must still produce attempt 3 — naively
  # using `attempt + 1` would collide with the existing attempt 2 on the
  # unique (authority, period, attempt) index. Two processes retrying the
  # same filing concurrently can still both compute the same next number;
  # that same unique index rejects the loser on save, which is the intended
  # resolution (one retry wins, the other raises RecordNotUnique/invalid).
  def build_retry
    unless status.in?(RETRYABLE_STATUSES)
      raise ArgumentError, "can only retry a failed or cancelled remittance (status is #{status})"
    end

    latest_attempt = self.class.where(authority:, period:).maximum(:attempt) || attempt

    self.class.new(
      authority:,
      jurisdiction:,
      period:,
      currency:,
      usd_amount_cents:,
      target_amount_cents:,
      rail:,
      attempt: latest_attempt + 1,
      status: "draft",
    )
  end

  private
    # Once money has moved — the row is `sent` or in a terminal state
    # (completed/failed/cancelled) — the payment facts are frozen: a later
    # write rewriting the amount, authority, or payment date of a payment
    # that already happened (a stale webhook, a buggy sync) would falsify a
    # record finance automation treats as the source of truth — the same
    # catch class as purchase-status resurrection.
    #
    # Status rules within the lock: a terminal row's status can never change
    # at all; a `sent` row may only advance to its real-world outcomes
    # (completed/failed/cancelled), never regress to draft/pending_approval/
    # funded — that would make an already-sent payment look actionable again.
    #
    # Two carve-outs: reconciliation fields may be filled in where they were
    # nil (the Wise statement sync learns local amounts and transfer IDs
    # after payment), and annotations (qbo_journal_entry_ref, notes) stay
    # freely writable.
    def payment_locked_rows_immutable
      return unless status_was.in?(PAYMENT_LOCKED_STATUSES)

      if status_changed?
        if status_was.in?(TERMINAL_STATUSES)
          errors.add(:status, "cannot change on a #{status_was} remittance")
        elsif !status.in?(SENT_OUTCOME_STATUSES)
          errors.add(:status, "can only move from sent to completed, failed, or cancelled")
        end
      end

      changed.each do |field|
        next if field == "status"

        if field.in?(FROZEN_WHEN_LOCKED)
          errors.add(field, "cannot change on a #{status_was} remittance")
        elsif field.in?(ENRICHABLE_WHEN_LOCKED) && attribute_was(field).present?
          errors.add(field, "cannot change once set on a #{status_was} remittance")
        end
      end
    end

    # Once a row is in pending_approval or funded, a human has reviewed and
    # signed off on specific numbers, so those numbers stop being freely
    # writable. Previously only `sent`/terminal rows were protected, which
    # meant the target-currency amount — the figure that actually leaves the
    # account — could be rewritten between approval and funding, and the
    # payment sent would not be the payment approved.
    #
    # Correcting an approved amount is still possible; it just costs the
    # approval. #revoke_approval! puts the row back to draft, the amounts are
    # editable again, and it has to be submitted for approval a second time.
    def approved_amounts_immutable
      return unless status_was.in?(APPROVAL_BOUND_STATUSES)
      # Going back to draft IS the sanctioned way to change these, and that
      # transition clears the approval, so a same-save amount change is fine.
      return if status == "draft"

      APPROVAL_BOUND_AMOUNTS.each do |field|
        next unless changed.include?(field)

        errors.add(field, "cannot change on a #{status_was} remittance without revoking the approval first")
      end
    end

    # At most one attempt per (authority, period) may be live (not failed or
    # cancelled) at a time — two concurrent live attempts would risk paying
    # the same filing twice. The unique (authority, period, attempt) index
    # keeps history append-only; this validation keeps it single-threaded.
    def single_live_attempt_per_filing
      return if status.in?(RETRYABLE_STATUSES)
      return if authority.blank? || period.blank?

      other_live = self.class.where(authority:, period:)
                       .where.not(status: RETRYABLE_STATUSES)
      other_live = other_live.where.not(id:) if persisted?
      if other_live.exists?
        errors.add(:base, "another live attempt already exists for #{authority} #{period}")
      end
    end
end
