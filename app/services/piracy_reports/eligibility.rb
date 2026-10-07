# frozen_string_literal: true

# Piracy reports are part of the "premium" tier, so a seller earns them with the store agent's
# predicate (User#eligible_for_store_agent?) rather than a bar of their own.
class PiracyReports::Eligibility
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
      errors << self.class.store_agent_gate_error unless seller.eligible_for_store_agent?
      errors << "The seller's payout record has no legal name to print in the notice" unless owner_identified?
      errors << "The product does not belong to the seller" unless product.user_id == seller.id
      errors << "The product is not published" unless product.published?
      errors << "The product has a collaborator" if product.confirmed_collaborator.present?
    end
  end

  def eligible?
    errors.empty?
  end

  private
    attr_reader :seller, :product

    # The notice prints the owner's legal name, which the agent's gate does not require.
    def owner_identified?
      seller.alive_user_compliance_info&.legal_entity_name.present?
    end
end
