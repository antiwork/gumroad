# frozen_string_literal: true

class PiracyReports::Eligibility
  def initialize(seller:, product:)
    @seller = seller
    @product = product
  end

  def errors
    [].tap do |errors|
      errors << "Piracy reports are not enabled for this seller" unless Feature.active?(:piracy_reports, seller)
      errors << "The seller's email is not confirmed" unless seller.confirmed?
      errors << "The seller has not completed payout setup" unless owner_identified?
      errors << "The seller's account is suspended" if seller.suspended?
      errors << "The product does not belong to the seller" unless product.user_id == seller.id
      errors << "The product is not published" unless product.published?
      errors << "The product has a collaborator" if product.confirmed_collaborator.present?
      errors << "The product has no successful sales" if successful_sales_count < PiracyReport::MIN_SUCCESSFUL_SALES
    end
  end

  def eligible?
    errors.empty?
  end

  private
    attr_reader :seller, :product

    # The notice prints the seller's legal name and address, so the record must carry both.
    def owner_identified?
      info = seller.alive_user_compliance_info
      info.present? && info.legal_entity_name.present? && info.legal_entity_street_address.present? && info.legal_entity_country.present?
    end

    def successful_sales_count
      Purchase.successful.where(link_id: product.id).limit(PiracyReport::MIN_SUCCESSFUL_SALES).count
    end
end
