# frozen_string_literal: true

class CollaboratorPresenter
  def initialize(seller:, collaborator: nil)
    @seller = seller
    @collaborator = collaborator
  end

  DEFAULT_PERCENT_COMMISSION = 50
  MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW = 10

  def new_collaborator_props
    collaborator_form_props.compact
  end

  def collaborator_props
    collaborator.as_json.merge(products:, percent_commission: collaborator.affiliate_percentage || DEFAULT_PERCENT_COMMISSION)
  end

  def edit_collaborator_props
    collaborator_form_props(
      apply_to_all_products: collaborator.apply_to_all_products?,
      dont_show_as_co_creator: collaborator.dont_show_as_co_creator?,
      email: nil,
      percent_commission: collaborator.affiliate_percentage,
      product_affiliates: collaborator.product_affiliates.includes(:product),
      title: collaborator.affiliate_user.display_name(prefer_email_over_default_username: true)
    ).compact
  end

  def inertia_shared_props
    {
      collaborators_disabled_reason: seller.has_brazilian_stripe_connect_account? ? "Collaborators with Brazilian Stripe accounts are not supported." : nil,
    }
  end

  def incoming_collaborator_props(collaborator)
    @collaborator = collaborator
    {
      percent_commission: collaborator.affiliate_percentage || DEFAULT_PERCENT_COMMISSION,
      apply_to_all_products: collaborator.apply_to_all_products,
      dont_show_as_co_creator: collaborator.dont_show_as_co_creator,
      id: collaborator.external_id,
      invitation_accepted: collaborator.invitation_accepted?,
      products: products(with_product_url: true),
      seller_avatar_url: collaborator.seller.avatar_url,
      seller_email: collaborator.seller.email,
      seller_name: collaborator.seller.display_name(prefer_email_over_default_username: true),
    }
  end

  private
    attr_reader :seller, :collaborator

    def collaborator_form_props(apply_to_all_products: true, dont_show_as_co_creator: false, email: "", percent_commission: DEFAULT_PERCENT_COMMISSION, product_affiliates: [], title: "New collaborator")
      {
        form_data: {
          id: collaborator&.external_id,
          email:,
          apply_to_all_products:,
          percent_commission:,
          dont_show_as_co_creator:,
          products: all_products(product_affiliates:, percent_commission:, apply_to_all_products:, dont_show_as_co_creator:),
        }.compact,
        page_metadata: {
          default_percent_commission: DEFAULT_PERCENT_COMMISSION,
          min_percent_commission: Collaborator::MIN_PERCENT_COMMISSION,
          max_percent_commission: Collaborator::MAX_PERCENT_COMMISSION,
          max_products_with_affiliates_to_show: MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW,
          title:,
        }.compact,
      }
    end

    def products(with_product_url: false)
      collaborator&.product_affiliates&.includes(:product)&.map do |pa|
        {
          id: pa.product.external_id,
          name: pa.product.name,
          percent_commission: pa.affiliate_percentage || collaborator.affiliate_percentage,
          url: with_product_url ? pa.product.long_url : nil,
        }.compact
      end
    end

    def all_products(apply_to_all_products: true, percent_commission: DEFAULT_PERCENT_COMMISSION, product_affiliates: [], dont_show_as_co_creator: false)
      seller.products.includes(product_affiliates: :affiliate).visible_and_not_archived.map do |product|
        product_affiliate = product.product_affiliates.find_by(affiliate: collaborator)
        has_another_collaborator = product.has_another_collaborator?(collaborator:)
        {
          id: product.external_id,
          name: product.name,
          has_another_collaborator:,
          has_affiliates: product.direct_affiliates.alive.exists?,
          published: product.published?,
          enabled: collaborator ? product_affiliate.present? : (!has_another_collaborator && product.published?),
          percent_commission: product_affiliate&.affiliate_percentage || percent_commission,
          dont_show_as_co_creator: product_affiliate&.dont_show_as_co_creator? || dont_show_as_co_creator,
        }
      end
    end
end
