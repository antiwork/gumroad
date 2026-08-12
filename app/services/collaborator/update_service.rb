# frozen_string_literal: true

class Collaborator::UpdateService
  def initialize(seller:, collaborator_id:, params:)
    @seller = seller
    @collaborator = seller.collaborators.find_by_external_id!(collaborator_id)
    @params = params
  end

  def process
    # Resolve the whole requested product set before touching anything: a bad or unowned id used to
    # raise partway through, after the rows for de-selected products had already been destroyed, so
    # the collaborator was left on a revenue share nobody asked for.
    requested_products = params[:products].map do |product_params|
      [seller.products.find_by_external_id!(product_params[:id]), product_params]
    end

    product_ids_to_lock = (collaborator.product_affiliates.pluck(:link_id) + requested_products.map { |product, _| product.id }).uniq
    result = nil

    loop do
      expanded_product_ids = nil

      ActiveRecord::Base.transaction do
        # ProductAffiliate locks its affiliate during autosave, so lock products first.
        Link.where(id: product_ids_to_lock).order(:id).lock.load
        Affiliate.where(id: collaborator.id).lock.load

        current_product_ids = ProductAffiliate.where(affiliate_id: collaborator.id).order(:link_id, :id).lock.pluck(:link_id)
        missing_product_ids = current_product_ids - product_ids_to_lock
        if missing_product_ids.any?
          expanded_product_ids = product_ids_to_lock | missing_product_ids
          raise ActiveRecord::Rollback
        end

        collaborator.reload(lock: true)
        collaborator.product_affiliates.reload

        default_basis_points = params[:percent_commission].presence&.to_i&.*(100)
        collaborator.affiliate_basis_points = default_basis_points if default_basis_points.present?
        collaborator.apply_to_all_products = params[:apply_to_all_products]
        collaborator.dont_show_as_co_creator = params[:dont_show_as_co_creator]

        enabled_product_ids = params[:products].map { _1[:id] }
        collaborator.product_affiliates.each do |pa|
          product_id = ObfuscateIds.encrypt(pa.link_id)
          pa.destroy! unless enabled_product_ids.include?(product_id)
        end

        collaborator.product_affiliates = requested_products.map do |product, product_params|
          product_affiliate = collaborator.product_affiliates.find_or_initialize_by(product:)
          product_affiliate.dont_show_as_co_creator = collaborator.apply_to_all_products ?
            collaborator.dont_show_as_co_creator :
            product_params[:dont_show_as_co_creator]
          percent_commission = collaborator.apply_to_all_products ? collaborator.affiliate_percentage : product_params[:percent_commission]
          product_affiliate.affiliate_basis_points = percent_commission.to_i * 100
          product_affiliate
        end

        if collaborator.save
          result = { success: true }
        else
          collaborator.errors.add(:base, collaborator.errors.full_messages.first) if collaborator.errors[:base].blank? && collaborator.errors.any?
          result = { success: false, collaborator: }
          raise ActiveRecord::Rollback
        end
      end

      break if expanded_product_ids.nil?

      product_ids_to_lock = expanded_product_ids
    end

    AffiliateMailer.collaborator_update(collaborator.id).deliver_later if result[:success]
    result
  end

  private
    attr_reader :seller, :collaborator, :params
end
