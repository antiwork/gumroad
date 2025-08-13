# frozen_string_literal: true

class CollaboratorPresenter
  def initialize(seller:, collaborator: nil)
    @seller = seller
    @collaborator = collaborator
  end

  def new_collaborator_props
    {
      products: all_products,
      collaborators_disabled_reason: seller.has_brazilian_stripe_connect_account? ? "Collaborators with Brazilian Stripe accounts are not supported." : nil,
    }
  end

  def collaborator_props
    collaborator.as_json.merge(products:)
  end

  def edit_collaborator_props
    collaborator&.as_json&.merge({
                                   products: all_products,
                                   collaborators_disabled_reason: seller.has_brazilian_stripe_connect_account? ? "Collaborators with Brazilian Stripe accounts are not supported." : nil,
                                 })
  end

  private
    attr_reader :seller, :collaborator

    def products
      collaborator&.product_affiliates&.includes(:product)&.map do |pa|
        {
          id: pa.product.external_id,
          name: pa.product.name,
          percent_commission: pa.affiliate_percentage,
        }
      end
    end

    def all_products
      seller.products.includes(product_affiliates: :affiliate).visible_and_not_archived.map do |product|
        product_affiliate = product.product_affiliates.find_by(affiliate: collaborator)

        {
          id: product.external_id,
          name: product.name,
          has_another_collaborator: product.has_another_collaborator?(collaborator:),
          has_affiliates: product.direct_affiliates.alive.exists?,
          published: product.published?,
          enabled: product_affiliate.present?,
          percent_commission: product_affiliate&.affiliate_percentage,
          dont_show_as_co_creator: product_affiliate&.dont_show_as_co_creator || false,
        }
      end
    end
end
