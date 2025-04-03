# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe ProfileSectionsController do
  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  it_behaves_like "authorize called for controller" do
    let(:record) { :profile_section }
    let(:request_params) { { id: "id" } }
  end

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    it "creates a product section" do
      products = create_list(:product, 2)
      expect do
        post :create, params: {
          type: "SellerProfileProductsSection",
          header: "Hello",
          hide_header: true,
          show_filters: false,
          shown_products: products.map(&:external_id),
          default_product_sort: "page_layout",
          add_new_products: true,
        }, as: :json
      end.to change { seller.seller_profile_products_sections.count }.from(0).to(1)
      section = seller.seller_profile_products_sections.sole
      expect(section).to have_attributes(
                                          type: "SellerProfileProductsSection",
                                          header: "Hello",
                                          hide_header: true,
                                          show_filters: false,
                                          shown_products: products.map(&:id),
                                          default_product_sort: "page_layout",
                                          add_new_products: true,
                                          product_id: nil
                                        )
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "id" => section.external_id })
    end

    it "creates a posts section" do
      create(:installment, :published, installment_type: Installment::FOLLOWER_TYPE, seller:, shown_on_profile: true)
      create(:installment, :published, installment_type: Installment::AUDIENCE_TYPE, seller:)
      posts = create_list(:published_installment, 2, installment_type: Installment::AUDIENCE_TYPE, seller:, shown_on_profile: true)
      expect do
        post :create, params: {
          type: "SellerProfilePostsSection", header: "Hello", hide_header: true, shown_posts: posts.map(&:external_id)
        }, as: :json
      end.to change { seller.seller_profile_posts_sections.count }.from(0).to(1)
      section = seller.seller_profile_posts_sections.reload.sole
      expect(section).to have_attributes(
                           type: "SellerProfilePostsSection",
                           header: "Hello",
                           hide_header: true,
                           shown_posts: posts.map(&:id),
                           product_id: nil
                         )
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "id" => section.external_id })
    end

    it "creates a featured product section" do
      product = create(:product, name: "Special product", user: seller)
      expect do
        post :create, params: {
          type: "SellerProfileFeaturedProductSection", header: "My amazing product", hide_header: false, featured_product_id: product.external_id,
        }, as: :json
      end.to change { seller.seller_profile_featured_product_sections.count }.from(0).to(1)
      section = seller.seller_profile_sections.reload.sole
      expect(section).to have_attributes(
        type: "SellerProfileFeaturedProductSection",
        header: "My amazing product",
        hide_header: false,
        featured_product_id: product.id,
        product_id: nil
      )
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "id" => section.external_id })
    end

    it "creates a subscribe section" do
      expect do
        post :create, params: {
          type: "SellerProfileSubscribeSection", header: "Subscribe to me!", hide_header: false, button_label: ""
        }, as: :json
      end.to change { seller.seller_profile_subscribe_sections.count }.from(0).to(1)
      section = seller.seller_profile_subscribe_sections.reload.sole
      expect(section).to have_attributes(
                           type: "SellerProfileSubscribeSection",
                           header: "Subscribe to me!",
                           hide_header: false,
                           button_label: "",
                           product_id: nil,
                         )
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "id" => section.external_id })
    end

    it "creates a rich text section" do
      params = {
        type: "SellerProfileRichTextSection",
        header: "Hello",
        hide_header: true,
        text: { "content" => nil, "anything_can_be_here" => "we don't validate this" }
      }
      expect do
        post :create, params: params, as: :json
      end.to change { seller.seller_profile_rich_text_sections.count }.from(0).to(1)
      section = seller.seller_profile_rich_text_sections.reload.sole
      expect(section).to have_attributes(params)
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "id" => section.external_id })
    end

    it "creates a section for a product" do
      product = create(:product, user: seller)
      params = {
        type: "SellerProfileFeaturedProductSection", product_id: product.external_id
      }
      expect do
        post :create, params:, as: :json
      end.to change { seller.seller_profile_featured_product_sections.count }.from(0).to(1)

      section = seller.seller_profile_sections.reload.sole
      expect(section.product).to eq product
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "id" => section.external_id })
    end

    it "creates a wishlists section" do
      wishlist = create(:wishlist, user: seller)

      expect do
        post :create, params: {
          type: "SellerProfileWishlistsSection", header: "Hello", hide_header: false, shown_wishlists: [wishlist.external_id]
        }, as: :json
      end.to change { seller.seller_profile_wishlists_sections.count }.from(0).to(1)
      section = seller.seller_profile_wishlists_sections.reload.sole
      expect(section).to have_attributes(
                           type: "SellerProfileWishlistsSection",
                           header: "Hello",
                           hide_header: false,
                           shown_wishlists: [wishlist.id],
                         )
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "id" => section.external_id })
    end

    it "returns an error for invalid types" do
      post :create, params: {
        type: "SellerProfileFakeSection", header: "Hello", hide_header: true, show_filters: false
      }, as: :json
      expect(response).to have_http_status :unprocessable_content
      expect(response.parsed_body).to eq({ "error" => "Invalid section type" })
    end

    it "returns an error for invalid data" do
      post :create, params: {
        type: "SellerProfileProductsSection", show_filters: "i hack u :)"
      }, as: :json
      expect(response).to have_http_status :unprocessable_content
      expect(response.parsed_body["error"]).to include("The property '#/show_filters' of type string did not match the following type: boolean")
    end
  end

  describe "PATCH update" do
    let(:section) { create(:seller_profile_products_section, seller:, header: "A!", shown_products: [1], hide_header: true) }

    it "updates the profile section" do
      products = create_list(:product, 2)
      patch :update, params: {
        id: section.external_id, header: "B!", shown_products: products.map(&:external_id)
      }, as: :json
      expect(section.reload).to have_attributes({
                                                  header: "B!",
                                                  shown_products: products.map(&:id),
                                                  hide_header: true
                                                })
      expect(response).to be_successful
    end

    it "disallows changing the shown_posts of a posts section" do
      post1 = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller:, shown_on_profile: true)
      post2 = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller:, shown_on_profile: true)
      section = create(:seller_profile_posts_section, seller:, shown_posts: [post1.id])
      patch :update, params: {
        id: section.external_id, header: "B!", shown_posts: [post1.external_id, post2.external_id]
      }, as: :json
      expect(section.reload).to have_attributes({ header: "B!", shown_posts: [post1.id] })
      expect(response).to be_successful
    end

    it "throws a 404 error if the section does not exist" do
      expect do
        patch :update, params: { id: "no", header: "B!" }, as: :json
      end.to raise_error ActiveRecord::RecordNotFound
    end

    it "throws a 404 error if the section does not belong to the seller" do
      expect do
        patch :update, params: { id: create(:seller_profile_products_section).external_id, header: "B!" }, as: :json
      end.to raise_error ActiveRecord::RecordNotFound
    end

    it "disallows changing the type" do
      patch :update, params: {
        id: section.external_id, type: "SellerProfileFakeSection"
      }, as: :json
      expect(section.reload.type).to eq "SellerProfileProductsSection"
    end

    it "disallows changing the product id" do
      patch :update, params: {
        id: section.external_id, product_id: create(:product).external_id
      }, as: :json
      expect(section.reload.product_id).to be_nil
    end

    it "returns an error for invalid data" do
      patch :update, params: { id: section.external_id, show_filters: "i hack u :)" }, as: :json
      expect(response).to have_http_status :unprocessable_content
      expect(response.parsed_body).to eq({ "error" => "The property '#/show_filters' of type string did not match the following type: boolean" })
    end

    context "rich content" do
      let(:product) { create(:product, user: seller) }
      let(:upsell) { create(:upsell, seller: seller, product: product, is_content_upsell: true) }
      let(:section) do
        create(
          :seller_profile_rich_text_section,
          seller: seller,
          header: "Hello",
          text: {
            "type" => "doc",
            "content" => [
              { "type" => "paragraph", "content" => [{ "text" => "hi", "type" => "text" }] },
              { "type" => "upsellCard", "attrs" => { "discount" => nil, "id" => upsell.external_id, "productId" => product.external_id } }
            ]
          }
        )
      end

      let(:new_text) do
        {
          "type" => "doc",
          "content" => [
            { "type" => "paragraph", "content" => [{ "text" => "hi", "type" => "text" }] },
            { "type" => "upsellCard", "attrs" => { "discount" => nil, "productId" => product.external_id } }
          ]
        }
      end

      it "invokes SaveContentUpsellsService" do
        expect(SaveContentUpsellsService).to receive(:new).with(
          seller: seller,
          content: new_text["content"].map { |node| ActionController::Parameters.new(node).permit! },
          old_content: section.text["content"]
        ).and_call_original
        patch :update, params: { id: section.external_id, text: new_text }, as: :json

        expect(response).to be_successful
        expect(upsell.reload).to be_deleted
        new_upsell = Upsell.last
        expect(section.reload.text["content"][1]["attrs"]["id"]).to eq(new_upsell.external_id)
        expect(new_upsell).to be_alive
        expect(new_upsell.product_id).to eq(product.id)
      end
    end
  end

  describe "DELETE destroy" do
    it "deletes the profile section" do
      create(:seller_profile_products_section, seller:)
      section = create(:seller_profile_products_section, seller:)

      expect do
        delete :destroy, params: { id: section.external_id }, as: :json
      end.to change { seller.seller_profile_sections.count }.from(2).to(1)

      expect(response).to be_successful
    end

    it "throws a 404 error if the section does not exist" do
      expect do
        delete :destroy, params: { id: "no" }, as: :json
      end.to raise_error ActiveRecord::RecordNotFound
    end

    it "throws a 404 error if the section does not belong to the seller" do
      expect do
        delete :destroy, params: { id: create(:seller_profile_products_section).external_id }, as: :json
      end.to raise_error ActiveRecord::RecordNotFound
    end
  end
end
