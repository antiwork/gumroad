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
# are terminal. Backfilled historical rows go straight to completed.
class TaxRemittance < ApplicationRecord
  include ExternalId

  RAILS = %w[wise stripe_global_payouts mercury].freeze
  STATUSES = %w[draft pending_approval funded sent completed failed cancelled].freeze
  TERMINAL_STATUSES = %w[completed failed cancelled].freeze

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
  validates :authority, uniqueness: { scope: :period }
  validates :currency, presence: true, length: { is: 3 }
  validates :usd_amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :target_amount_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :rail, presence: true, inclusion: { in: RAILS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :paid_at, presence: true, if: -> { status.in?(%w[sent completed]) }

  scope :for_period, ->(period) { where(period:) }
  scope :in_progress, -> { where.not(status: TERMINAL_STATUSES) }
  scope :completed, -> { where(status: "completed") }
  scope :awaiting_approval, -> { where(status: "pending_approval") }

  validate :terminal_status_immutable, on: :update

  def self.period_for(date)
    "#{date.year}-Q#{(date.month - 1) / 3 + 1}"
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  private
    # Once a remittance reaches a terminal state (completed/failed/cancelled),
    # its status is frozen. A later status write silently resurrecting a
    # completed payment (e.g. a stale webhook or a buggy sync) would re-count
    # real money — the same catch class as purchase-status resurrection.
    def terminal_status_immutable
      return unless status_changed?
      return unless status_was.in?(TERMINAL_STATUSES)

      errors.add(:status, "cannot change from terminal state #{status_was}")
    end
end
