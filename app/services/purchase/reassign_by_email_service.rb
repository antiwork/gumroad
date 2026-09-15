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

    # Unmatched originals swept along with a recurring charge count toward the
    # fingerprint guard; a third party's original (gift sender) stays put and does not.
    mutable_purchases = purchases.dup
    mutable_purchase_id_set = purchase_id_set.dup
    sweepable_original_purchase_ids = Set.new
    purchases.each do |purchase|
      next unless purchase.subscription.present? && !purchase.is_original_subscription_purchase?

      original_purchase = purchase.original_purchase
      next if original_purchase.blank? || mutable_purchase_id_set.include?(original_purchase.id)
      next unless same_requester?(original_purchase, purchase)

      mutable_purchases << original_purchase
      mutable_purchase_id_set.add(original_purchase.id)
      sweepable_original_purchase_ids.add(original_purchase.id)
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
    pending_original_ids = sweepable_original_purchase_ids.dup
    moved_original_ids = Set.new

    purchases.each do |purchase|
      purchase.email = @to_email
      # A purchase hidden from the old account's library (is_deleted_by_buyer)
      # stays hidden after the move, so the buyer's new library looks empty.
      # Transferring the library means the buyer wants these purchases visible
      # again, so clear the flag as part of the reassignment.
      purchase.is_deleted_by_buyer = false

      transfer_subscription = purchase.subscription.present?
      if transfer_subscription && !purchase.is_original_subscription_purchase?
        original_purchase = purchase.original_purchase
        if pending_original_ids.delete?(original_purchase.id) && original_purchase.update(email: @to_email, purchaser_id: target_user&.id, is_deleted_by_buyer: false)
          moved_original_ids.add(original_purchase.id)
          reassigned_purchase_ids << original_purchase.id if original_purchase.saved_changes?
        end

        # Several recurring rows can share one original: the subscription follows a swept
        # original only once it actually moved, and a matched original moves it from its own row.
        if sweepable_original_purchase_ids.include?(original_purchase.id)
          transfer_subscription = moved_original_ids.include?(original_purchase.id)
        elsif purchase_id_set.include?(original_purchase.id)
          transfer_subscription = false
        end
      end

      purchase.purchaser_id = target_user&.id

      if purchase.save
        reassigned_purchase_ids << purchase.id
        if transfer_subscription
          purchase.subscription.update(user: target_user)
          # A gifted membership without a destination account routes renewal
          # emails through gift.giftee_email, so move that pointer with the rows.
          gift = purchase.original_purchase.gift_given if purchase.original_purchase&.is_gift_sender_purchase?
          gift.update(giftee_email: @to_email) if gift.present? && gift.giftee_email.to_s.casecmp?(@from_email.to_s)
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
    # A gift sender's original sits behind the giftee's membership with a different
    # email and card, so only sweep an unmatched original owned by the same requester.
    def same_requester?(original_purchase, purchase)
      return true if original_purchase.email.to_s.casecmp?(@from_email.to_s)

      purchase.purchaser_id.present? && original_purchase.purchaser_id == purchase.purchaser_id
    end

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
