# frozen_string_literal: true

require "spec_helper"

describe CollaboratorPresenter do
  describe "#new_collaborator_props" do
    let(:seller) { create(:user) }
    let!(:visible_product) { create(:product, user: seller) }
    let!(:archived_product) { create(:product, user: seller, archived: true) }
    let!(:deleted_product) { create(:product, user: seller, deleted_at: 1.day.ago) }
    let!(:product_with_affiliates) { create(:product, user: seller).tap { |product| create(:direct_affiliate, products: [product]) } }
    let!(:ineligible_product) { create(:product, user: seller).tap { |product| create(:collaborator, products: [product]) } }
    let!(:product_with_global_affiliate) do
      create(:product, user: seller, purchase_disabled_at: Time.current).tap do |product|
        create(:product_affiliate, product:, affiliate: create(:user).global_affiliate)
      end
    end
    let!(:product_with_deleted_collaborator) do
      create(:product, user: seller).tap do |product|
        create(:collaborator, seller:, products: [product], deleted_at: 1.day.ago)
      end
    end

    it "returns the seller's visible and not archived products" do
      props = described_class.new(seller:).new_collaborator_props

      expect(props[:form_data][:products]).to eq([
                                                   { id: visible_product.external_id, name: visible_product.name, published: true, has_another_collaborator: false, has_affiliates: false, enabled: true, percent_commission: 50, dont_show_as_co_creator: false },
                                                   { id: product_with_affiliates.external_id, name: product_with_affiliates.name, published: true, has_another_collaborator: false, has_affiliates: true, enabled: true, percent_commission: 50, dont_show_as_co_creator: false },
                                                   { id: ineligible_product.external_id, name: ineligible_product.name, published: true, has_another_collaborator: true, has_affiliates: false, enabled: false, percent_commission: 50, dont_show_as_co_creator: false },
                                                   { id: product_with_global_affiliate.external_id, name: product_with_global_affiliate.name, published: false, has_another_collaborator: false, has_affiliates: false, enabled: false, percent_commission: 50, dont_show_as_co_creator: false },
                                                   { id: product_with_deleted_collaborator.external_id, name: product_with_deleted_collaborator.name, published: true, has_another_collaborator: false, has_affiliates: false, enabled: true, percent_commission: 50, dont_show_as_co_creator: false },
                                                 ])
      expect(props[:form_data]).to_not include(:id)
      expect(props[:form_data]).to include(
        email: "",
        apply_to_all_products: true,
        percent_commission: CollaboratorPresenter::DEFAULT_PERCENT_COMMISSION,
        dont_show_as_co_creator: false,
      )

      expect(props[:page_metadata]).to eq(
       title: "New collaborator",
       default_percent_commission: CollaboratorPresenter::DEFAULT_PERCENT_COMMISSION,
       min_percent_commission: Collaborator::MIN_PERCENT_COMMISSION,
       max_percent_commission: Collaborator::MAX_PERCENT_COMMISSION,
       max_products_with_affiliates_to_show: CollaboratorPresenter::MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW,
     )
    end
  end

  describe "#collaborator_props" do
    let(:seller) { create(:user) }
    let(:visible_product) { create(:product, user: seller) }
    let!(:archived_product) { create(:product, user: seller, archived: true) }
    let!(:deleted_product) { create(:product, user: seller, deleted_at: 1.day.ago) }
    let!(:ineligible_product) { create(:product, user: seller).tap { |product| create(:collaborator, products: [product]) } }
    let(:collaborator) { create(:collaborator, seller:, products: [visible_product]) }

    it "returns the collaborator and its products" do
      props = described_class.new(seller:, collaborator:).collaborator_props

      expect(props.except(:products)).to match(collaborator.as_json)
      expect(props[:products]).to match_array([{ id: visible_product.external_id, name: visible_product.name, percent_commission: collaborator.affiliate_percentage }])
    end
  end

  describe "#edit_collaborator_props" do
    let(:seller) { create(:user) }
    let!(:visible_product) { create(:product, user: seller) }
    let!(:archived_product) { create(:product, user: seller, archived: true) }
    let!(:deleted_product) { create(:product, user: seller, deleted_at: 1.day.ago) }
    let!(:product_with_affiliates) { create(:product, user: seller).tap { |product| create(:direct_affiliate, products: [product]) } }
    let!(:ineligible_product) { create(:product, user: seller).tap { |product| create(:collaborator, products: [product]) } }
    let!(:collaborator) { create(:collaborator, seller:, products: [visible_product]) }
    let!(:product_with_global_affiliate) do
      create(:product, user: seller, purchase_disabled_at: Time.current).tap do |product|
        create(:product_affiliate, product:, affiliate: create(:user).global_affiliate)
      end
    end
    let!(:product_with_deleted_collaborator) do
      create(:product, user: seller).tap do |product|
        create(:collaborator, seller:, products: [product], deleted_at: 1.day.ago)
      end
    end

    it "returns the collaborator and eligible products" do
      props = described_class.new(seller:, collaborator:).edit_collaborator_props
      default_commission = collaborator.affiliate_percentage || CollaboratorPresenter::DEFAULT_PERCENT_COMMISSION

      expect(props[:form_data]).to include(
        id: collaborator.external_id,
        apply_to_all_products: true,
        percent_commission: collaborator.affiliate_percentage,
        dont_show_as_co_creator: collaborator.dont_show_as_co_creator?,
      )

      expect(props[:form_data][:products]).to eq([
                                                   { id: visible_product.external_id, name: visible_product.name, published: true, has_another_collaborator: false, has_affiliates: false, enabled: true, percent_commission: default_commission, dont_show_as_co_creator: false },
                                                   { id: product_with_affiliates.external_id, name: product_with_affiliates.name, published: true, has_another_collaborator: false, has_affiliates: true, enabled: false, percent_commission: default_commission, dont_show_as_co_creator: false },
                                                   { id: ineligible_product.external_id, name: ineligible_product.name, published: true, has_another_collaborator: true, has_affiliates: false, enabled: false, percent_commission: default_commission, dont_show_as_co_creator: false },
                                                   { id: product_with_global_affiliate.external_id, name: product_with_global_affiliate.name, published: false, has_another_collaborator: false, has_affiliates: false, enabled: false, percent_commission: default_commission, dont_show_as_co_creator: false },
                                                   { id: product_with_deleted_collaborator.external_id, name: product_with_deleted_collaborator.name, published: true, has_another_collaborator: false, has_affiliates: false, enabled: false, percent_commission: default_commission, dont_show_as_co_creator: false },
                                                 ])

      expect(props[:page_metadata]).to eq(
        title: collaborator.affiliate_user.display_name(prefer_email_over_default_username: true),
        default_percent_commission: CollaboratorPresenter::DEFAULT_PERCENT_COMMISSION,
        min_percent_commission: Collaborator::MIN_PERCENT_COMMISSION,
        max_percent_commission: Collaborator::MAX_PERCENT_COMMISSION,
        max_products_with_affiliates_to_show: CollaboratorPresenter::MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW,
      )
    end
  end

  describe "#incoming_collaborator_props" do
    let(:seller) { create(:user) }
    let(:affiliate_user) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:collaborator) { create(:collaborator, seller:, affiliate_user:, products: [product], affiliate_basis_points: 30_00) }
    let(:product_affiliate) { collaborator.product_affiliates.first }

    it "returns the collaborator with seller info and products" do
      props = described_class.new(seller: affiliate_user).incoming_collaborator_props(collaborator)

      expect(props).to include(
        id: collaborator.external_id,
        apply_to_all_products: collaborator.apply_to_all_products,
        percent_commission: collaborator.affiliate_percentage,
        dont_show_as_co_creator: collaborator.dont_show_as_co_creator,
        invitation_accepted: collaborator.invitation_accepted?,
        seller_email: seller.email,
        seller_name: seller.display_name(prefer_email_over_default_username: true),
        seller_avatar_url: seller.avatar_url,
      )
      expect(props[:products]).to match_array([
                                                {
                                                  id: product.external_id,
                                                  url: product.long_url,
                                                  name: product.name,
                                                  percent_commission: collaborator.affiliate_percentage,
                                                },
                                              ])
    end
  end

  describe "#inertia_shared_props" do
    let(:seller) { create(:user) }

    it "returns nil when seller does not have a Brazilian Stripe Connect account" do
      props = described_class.new(seller:).inertia_shared_props

      expect(props[:collaborators_disabled_reason]).to be_nil
    end

    it "returns collaborators supported as false if using a Brazilian Stripe Connect account" do
      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: seller, country: "BR")
      seller.update!(check_merchant_account_is_linked: true)
      expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      props = described_class.new(seller:).inertia_shared_props

      expect(props[:collaborators_disabled_reason]).to eq "Collaborators with Brazilian Stripe accounts are not supported."
    end
  end
end
