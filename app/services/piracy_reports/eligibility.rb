# frozen_string_literal: true

# Piracy reports are part of the "premium" tier, so a seller earns them with the store agent's
# predicate (User#eligible_for_store_agent?). The product also needs a sale of its own: an
# account-wide bar alone lets a seller re-upload someone else's work and file against the original.
class PiracyReports::Eligibility
  # Lets staff test from an account that has not earned the feature. The checks that keep the
  # notice true (legal name, ownership, published product, no collaborator) still apply.
  SKIP_SALES_CHECKS_FLAG = :piracy_reports_skip_sales_checks

  def self.store_agent_gate_error
    minimum = MoneyFormatter.format(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT, :usd, no_cents_if_whole: true, symbol: true)
    "Piracy reports unlock with the Agent: confirm your email, complete a payout and reach #{minimum} in sales"
  end

  def initialize(seller:, product:)
    @seller = seller
    @product = product
  end

  def errors
    [].tap do |errors|
      errors << "Piracy reports are not enabled for this seller" unless Feature.active?(:piracy_reports, seller)
      errors << "The seller's account is suspended" if seller.suspended?
      # A suspended seller gets the real blocker instead of steps that cannot clear it.
      errors << self.class.store_agent_gate_error unless seller.suspended? || skip_sales_checks? || seller.eligible_for_store_agent?
      errors << "The seller's payout record has no legal name to print in the notice" unless owner_identified?
      errors << "The product does not belong to the seller" unless product.user_id == seller.id
      errors << "The product is not published" unless product.published?
      errors << "The product has a collaborator" if product.confirmed_collaborator.present?
      errors << "The product has no successful sales" unless skip_sales_checks? || successful_sales_count >= PiracyReport::MIN_SUCCESSFUL_SALES
    end
  end

  def eligible?
    errors.empty?
  end

  private
    attr_reader :seller, :product

    def skip_sales_checks?
      Feature.active?(SKIP_SALES_CHECKS_FLAG, seller)
    end

    # The notice prints the owner's legal name, which the agent's gate does not require.
    def owner_identified?
      seller.alive_user_compliance_info&.legal_entity_name.present?
    end

    def successful_sales_count
      Purchase.successful.where(link_id: product.id).limit(PiracyReport::MIN_SUCCESSFUL_SALES).count
    end
end
