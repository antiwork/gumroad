# frozen_string_literal: true

class Collaborator::CreateService
  def initialize(seller:, params:)
    @seller = seller
    @params = params
  end

  def process
    collaborating_user = User.find_by(email: params[:email])

    collaborator = seller.collaborators.build(
      affiliate_user: collaborating_user,
    )

    if collaborating_user.nil?
      collaborator.errors.add(:base, "The email address isn't associated with a Gumroad account.")
      return { success: false, collaborator: }
    end

    if seller.collaborators.alive.exists?(affiliate_user: collaborating_user)
      collaborator.errors.add(:base, "The user is already a collaborator")
      return { success: false, collaborator: }
    end

    collaborator.assign_attributes(
      apply_to_all_products: params[:apply_to_all_products],
      dont_show_as_co_creator: params[:dont_show_as_co_creator],
      affiliate_basis_points: params[:percent_commission].presence&.to_i&.*(100),
    )

    collaborator.build_collaborator_invitation if require_approval?(seller:, collaborating_user:)

    params[:products].each do |product_params|
      product = seller.products.find_by_external_id(product_params[:id])
      unless product
        collaborator.errors.add(:base, "Product not found")
        break
      end

      product_affiliate = collaborator.product_affiliates.build(product:)
      percent_commission = params[:apply_to_all_products] ? params[:percent_commission] : product_params[:percent_commission]
      product_affiliate.affiliate_basis_points = percent_commission.to_i * 100
      product_affiliate.dont_show_as_co_creator = params[:apply_to_all_products] ?
        collaborator.dont_show_as_co_creator :
        product_params[:dont_show_as_co_creator]
    end

    return { success: false, collaborator: } if collaborator.errors.any?

    if collaborator.save
      deliver_email_for(collaborator)
      { success: true }
    else
      collaborator.errors.add(:base, collaborator.errors.full_messages.first) if collaborator.errors[:base].blank? && collaborator.errors.any?
      { success: false, collaborator: }
    end
  end

  private
    attr_reader :seller, :params

    def require_approval?(seller:, collaborating_user:)
      !collaborating_user.collaborators
        .invitation_accepted
        .alive
        .exists?(affiliate_user: seller)
    end

    def deliver_email_for(collaborator)
      if collaborator.collaborator_invitation.present?
        AffiliateMailer.collaborator_invited(collaborator.id).deliver_later
      else
        AffiliateMailer.collaborator_creation(collaborator.id).deliver_later
      end
    end
end
