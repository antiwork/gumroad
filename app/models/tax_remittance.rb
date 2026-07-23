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

  RAILS = %w[wise stripe_global_payouts mercury].freeze
  STATUSES = %w[draft pending_approval funded sent completed failed cancelled].freeze
  TERMINAL_STATUSES = %w[completed failed cancelled].freeze
  # Terminal statuses that a retry attempt may follow. `completed` is absent
  # on purpose: the money arrived, there is nothing to retry.
  RETRYABLE_STATUSES = %w[failed cancelled].freeze

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
  validate :single_live_attempt_per_filing

  def self.period_for(date)
    "#{date.year}-Q#{(date.month - 1) / 3 + 1}"
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
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
