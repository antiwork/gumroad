# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"

describe Api::Internal::Collaborators::IncomingsController do
  let!(:seller1) { create(:user) }
  let!(:seller2) { create(:user) }
  let!(:invited_user) { create(:user) }

  let!(:seller1_product) { create(:product, user: seller1) }
  let!(:seller2_product) { create(:product, user: seller2) }

  let!(:pending_collaboration) do
    create(
      :collaborator,
      :with_pending_invitation,
      seller: seller1,
      affiliate_user: invited_user,
    )
  end
  let!(:pending_collaboration_product) do
    create(:product_affiliate, affiliate: pending_collaboration, product: seller1_product)
  end

  let!(:accepted_collaboration) do
    create(
      :collaborator,
      seller: seller2,
      affiliate_user: invited_user
    )
  end
  let!(:accepted_collaboration_product) do
    create(:product_affiliate, affiliate: accepted_collaboration, product: seller2_product)
  end

  let!(:other_seller_pending_collaboration) do
    create(
      :collaborator,
      :with_pending_invitation,
      seller: seller1,
      affiliate_user: seller2
    )
  end


  describe "GET index" do
    before { sign_in invited_user }

    it_behaves_like "authentication required for action", :get, :index

    it "returns the pending collaborations for the signed in user" do
      get :index, format: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["collaborators"]).to match_array(
        [
          {
            id: accepted_collaboration.external_id,
            seller_email: seller2.email,
            seller_name: seller2.display_name(prefer_email_over_default_username: true),
            seller_avatar_url: seller2.avatar_url,
            apply_to_all_products: accepted_collaboration.apply_to_all_products,
            affiliate_percentage: accepted_collaboration.affiliate_percentage,
            dont_show_as_co_creator: accepted_collaboration.dont_show_as_co_creator,
            invitation_accepted: accepted_collaboration.invitation_accepted?,
            products: [
              {
                id: seller2_product.external_id,
                url: seller2_product.long_url,
                name: seller2_product.name,
                affiliate_percentage: accepted_collaboration_product.affiliate_percentage,
                dont_show_as_co_creator: accepted_collaboration_product.dont_show_as_co_creator,
              }
            ]
          },
          {
            id: pending_collaboration.external_id,
            seller_email: seller1.email,
            seller_name: seller1.display_name(prefer_email_over_default_username: true),
            seller_avatar_url: seller1.avatar_url,
            apply_to_all_products: pending_collaboration.apply_to_all_products,
            affiliate_percentage: pending_collaboration.affiliate_percentage,
            dont_show_as_co_creator: pending_collaboration.dont_show_as_co_creator,
            invitation_accepted: pending_collaboration.invitation_accepted?,
            products: [
              {
                id: seller1_product.external_id,
                url: seller1_product.long_url,
                name: seller1_product.name,
                affiliate_percentage: pending_collaboration_product.affiliate_percentage,
                dont_show_as_co_creator: pending_collaboration_product.dont_show_as_co_creator,
              }
            ]
          }
        ]
      )
    end
  end
end
