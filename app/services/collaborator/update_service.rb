# frozen_string_literal: true

class Collaborator::UpdateService
  def initialize(seller:, collaborator_id:, params:)
    @seller = seller
    @collaborator = seller.collaborators.find_by_external_id!(collaborator_id)
    @params = params
  end

  def process
    default_basis_points = params[:percent_commission].presence&.to_i&.*(100)
    collaborator.affiliate_basis_points = default_basis_points if default_basis_points.present?
    collaborator.apply_to_all_products = params[:apply_to_all_products]
    collaborator.dont_show_as_co_creator = params[:dont_show_as_co_creator]

    enabled_product_ids = params[:products].map { _1[:id] }
    collaborator.product_affiliates.map do |pa|
      product_id = ObfuscateIds.encrypt(pa.link_id)
      pa.destroy! unless enabled_product_ids.include?(product_id)
    end

    collaborator.product_affiliates = params[:products].map do |product_params|
      product = seller.products.find_by_external_id!(product_params[:id])
      product_affiliate = collaborator.product_affiliates.find_or_initialize_by(product:)
      product_affiliate.dont_show_as_co_creator = collaborator.apply_to_all_products ?
        collaborator.dont_show_as_co_creator :
        product_params[:dont_show_as_co_creator]
      percent_commission = collaborator.apply_to_all_products ? collaborator.affiliate_percentage : product_params[:percent_commission]
      product_affiliate.affiliate_basis_points = percent_commission.to_i * 100
      product_affiliate
    end

    if collaborator.save
      AffiliateMailer.collaborator_update(collaborator.id).deliver_later
      { success: true }
    else
      collaborator.errors.add(:base, collaborator.errors.full_messages.first) if collaborator.errors[:base].blank? && collaborator.errors.any?
      { success: false, collaborator: collaborator }
    end
  end

  private
    attr_reader :seller, :collaborator, :params
end
