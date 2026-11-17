# frozen_string_literal: true

# Aggregates fraud signals per seller, which nothing did before: an early fraud warning refunds its
# own purchase and blocks that buyer individually, and Radar::SellerRiskStatsService has only ever
# been read by the admin panel. This scans and reports; suspending, blocking or holding a payout
# stays a human decision.
class Radar::SellerFraudSignalScanService
  # The window Radar::SellerRiskStatsService measures, and the same span for the signals and for the
  # sales they are a share of — a share over mismatched windows moves for reasons unrelated to the
  # seller.
  LOOKBACK_PERIOD = 90.days

  # A share means nothing below a real sales base: two disputes on five sales is 40% and is only a
  # small shop having a bad month.
  MIN_SUCCESSFUL_SALES = 25

  # Provisional: low enough to report a seller on the way up rather than once the damage is done. It
  # has to be replayed against known-bad accounts before it decides anything automatically.
  FRAUD_SIGNAL_SHARE_THRESHOLD = 0.25

  # Bounds the one expensive step. Sellers that appear in a dispute or an early fraud warning are a
  # rare set, so this only stops a pathological window from becoming an unbounded IN list.
  MAX_CANDIDATES = 5_000

  def self.call
    new.call
  end

  # => { sellers: [{ seller_id:, email:, created_at:, successful_sales:, disputes:,
  #                  fraudulent_disputes:, efws:, signals:, share: }], truncated: }
  def call
    window = LOOKBACK_PERIOD.ago

    disputes = non_won_dispute_counts(window)
    efws = early_fraud_warning_counts(window)

    candidate_ids = (disputes.keys | efws.keys)
    truncated = candidate_ids.size > MAX_CANDIDATES
    candidate_ids = candidate_ids.first(MAX_CANDIDATES)

    sales = successful_sales_counts(candidate_ids, window)

    sellers = candidate_ids.filter_map do |seller_id|
      successful_sales = sales.fetch(seller_id, 0)
      next if successful_sales < MIN_SUCCESSFUL_SALES

      dispute_counts = disputes.fetch(seller_id, {})
      total_disputes = dispute_counts.values.sum
      efw_count = efws.fetch(seller_id, 0)
      signals = total_disputes + efw_count
      share = signals.to_f / successful_sales
      next if share < FRAUD_SIGNAL_SHARE_THRESHOLD

      {
        seller_id:,
        successful_sales:,
        disputes: total_disputes,
        fraudulent_disputes: dispute_counts.fetch(Dispute::REASON_FRAUDULENT, 0) +
          dispute_counts.fetch(Dispute::REASON_UNRECOGNIZED, 0),
        efws: efw_count,
        signals:,
        share: share.round(4),
      }
    end

    sellers.sort_by! { |seller| [-seller[:share], -seller[:signals], seller[:seller_id]] }
    identities = seller_identities(sellers.map { |seller| seller[:seller_id] })

    {
      sellers: sellers.map { |seller| seller.merge(identities.fetch(seller[:seller_id], {})) },
      truncated:,
    }
  end

  private
    # One seller can carry several dispute reasons, and only the fraudulent ones matter as a fraud
    # signal — so the counts come back keyed by both and the split is reported rather than lost.
    def non_won_dispute_counts(window)
      Dispute.excluding_paypal_processor
             .where.not(state: "won")
             .where("disputes.created_at >= ?", window)
             .where.not(seller_id: nil)
             .group(:seller_id, :reason)
             .count
             .each_with_object({}) do |((seller_id, reason), count), memo|
               (memo[seller_id] ||= Hash.new(0))[reason] += count
             end
    end

    # An early fraud warning hangs off exactly one purchase or one charge (the model validates the
    # XOR), so these two mappings cannot describe the same warning and adding them cannot double
    # count. A charge-linked warning belongs to a multi-item checkout the purchase join cannot see.
    def early_fraud_warning_counts(window)
      scope = EarlyFraudWarning.where("purchase_early_fraud_warnings.created_at >= ?", window)

      by_purchase = scope.joins(:purchase)
                         .where.not(purchases: { seller_id: nil })
                         .group("purchases.seller_id")
                         .count
      by_charge = scope.joins(:charge)
                       .where.not(charges: { seller_id: nil })
                       .group("charges.seller_id")
                       .count

      by_purchase.merge(by_charge) { |_seller_id, from_purchase, from_charge| from_purchase + from_charge }
    end

    def successful_sales_counts(seller_ids, window)
      return {} if seller_ids.empty?

      Purchase.successful
              .excluding_paypal_processor
              .where(seller_id: seller_ids)
              .where("purchases.created_at >= ?", window)
              .group(:seller_id)
              .count
    end

    def seller_identities(seller_ids)
      return {} if seller_ids.empty?

      User.where(id: seller_ids).pluck(:id, :email, :created_at).to_h do |id, email, created_at|
        [id, { email:, created_at: }]
      end
    end
end
