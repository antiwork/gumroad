# frozen_string_literal: true

class Purchase::ReassignByEmailService
  # Maximum number of distinct payment cards (by last-4) a single from_email batch
  # may span before the reassignment is treated as a possible harvesting attempt
  # and routed to manual review. 4+ distinct cards trips the guard.
  MAX_DISTINCT_CARDS = 3

  Result = Struct.new(:success, :reassigned_purchase_ids, :error_message, :reason, keyword_init: true) do
    def success? = success
    def count = reassigned_purchase_ids.size
  end

  def initialize(from_email:, to_email:, confirmed_override: false)
    @from_email = from_email
    @to_email = to_email
    @confirmed_override = confirmed_override
  end

  def perform
    if @from_email.blank? || @to_email.blank?
      return Result.new(success: false, reassigned_purchase_ids: [], reason: :missing_params, error_message: "Both 'from' and 'to' email addresses are required")
    end

    if @from_email.to_s.casecmp(@to_email.to_s).zero?
      return Result.new(success: false, reassigned_purchase_ids: [], reason: :no_changes, error_message: "from and to emails are the same")
    end

    purchases = Purchase.where(email: @from_email).includes(subscription: :original_purchase).to_a
    if purchases.empty?
      return Result.new(success: false, reassigned_purchase_ids: [], reason: :not_found, error_message: "No purchases found for email: #{@from_email}")
    end

    purchase_id_set = purchases.map(&:id).to_set

    # Every purchase this service may mutate, including original subscription
    # purchases that are not themselves matched by from_email but get reassigned
    # alongside a recurring charge.
    mutable_purchases = purchases.dup
    mutable_purchase_id_set = purchase_id_set.dup
    purchases.each do |purchase|
      next unless purchase.subscription.present? && !purchase.is_original_subscription_purchase?

      original_purchase = purchase.original_purchase
      if original_purchase.present? && !mutable_purchase_id_set.include?(original_purchase.id)
        mutable_purchases << original_purchase
        mutable_purchase_id_set.add(original_purchase.id)
      end
    end

    if mutable_purchases.any?(&:is_reassignment_locked?)
      return Result.new(success: false, reassigned_purchase_ids: [], reason: :locked, error_message: "One or more purchases are under review and cannot be reassigned")
    end

    unless @confirmed_override
      distinct_fingerprints = mutable_purchases.map { |purchase| payment_fingerprint(purchase) }.compact.uniq
      if distinct_fingerprints.size > MAX_DISTINCT_CARDS
        return Result.new(success: false, reassigned_purchase_ids: [], reason: :fingerprint_anomaly, error_message: "This reassignment spans an unusual number of distinct payment methods and requires manual review")
      end
    end

    target_user = User.alive.by_email(@to_email).first
    reassigned_purchase_ids = []

    purchases.each do |purchase|
      purchase.email = @to_email

      if purchase.subscription.present? && !purchase.is_original_subscription_purchase? && !purchase_id_set.include?(purchase.original_purchase.id)
        if purchase.original_purchase.update(email: @to_email, purchaser_id: target_user&.id)
          reassigned_purchase_ids << purchase.original_purchase.id if purchase.original_purchase.saved_changes?
          purchase.subscription.update(user: target_user)
        end
      end

      purchase.purchaser_id = target_user&.id

      if purchase.save
        reassigned_purchase_ids << purchase.id
        if purchase.is_original_subscription_purchase? && purchase.subscription.present?
          purchase.subscription.update(user: target_user)
        end
      end
    end

    if reassigned_purchase_ids.empty?
      return Result.new(success: false, reassigned_purchase_ids: [], reason: :no_changes, error_message: "No purchases were reassigned")
    end

    CustomerMailer.grouped_receipt(reassigned_purchase_ids).deliver_later(queue: "critical")

    Result.new(success: true, reassigned_purchase_ids: reassigned_purchase_ids, reason: nil, error_message: nil)
  end

  private
    # Returns a normalized, distinct payment-method signal for a purchase.
    # Card purchases collapse to the card's last 4 digits; non-card processors
    # (e.g. PayPal) store an email or other token in card_visual, so fall back to
    # the normalized full visual rather than silently dropping it.
    def payment_fingerprint(purchase)
      visual = purchase.card_visual.to_s.strip
      return nil if visual.blank?
      return "other:#{visual.downcase}" if visual.match?(/[\r\n]/)

      if ChargeableVisual.is_cc_visual(visual)
        last_four = visual.gsub(/[^0-9]/, "")[-4..]
        return "card:#{last_four}" if last_four.present?
      end

      "other:#{visual.downcase}"
    end
end
