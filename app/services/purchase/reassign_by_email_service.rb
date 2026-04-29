# frozen_string_literal: true

class Purchase::ReassignByEmailService
  Result = Struct.new(:success, :reassigned_purchase_ids, :error_message, :reason, keyword_init: true) do
    def success? = success
    def count = reassigned_purchase_ids.size
  end

  def initialize(from_email:, to_email:)
    @from_email = from_email
    @to_email = to_email
  end

  def perform
    if @from_email.blank? || @to_email.blank?
      return Result.new(success: false, reassigned_purchase_ids: [], reason: :missing_params, error_message: "Both 'from' and 'to' email addresses are required")
    end

    if @from_email.to_s.casecmp(@to_email.to_s).zero?
      return Result.new(success: false, reassigned_purchase_ids: [], reason: :no_changes, error_message: "from and to emails are the same")
    end

    purchases = Purchase.where(email: @from_email).to_a
    if purchases.empty?
      return Result.new(success: false, reassigned_purchase_ids: [], reason: :not_found, error_message: "No purchases found for email: #{@from_email}")
    end

    purchase_id_set = purchases.map(&:id).to_set
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
end
