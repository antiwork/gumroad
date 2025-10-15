# frozen_string_literal: true

require "spec_helper"
require "shared_examples/affiliate_cookie_concern"
require "shared_examples/authorize_called"
require "shared_examples/collaborator_access"
require "shared_examples/with_sorting_and_pagination"
require "inertia_rails/rspec"

def e404_test(action)
  it "404s when link isn't found" do
    expect { get action, params: { id: "NOT real" } }.to raise_error(ActionController::RoutingError)
  end
end

describe LinksController, :vcr, inertia: true do
  render_views

  context "within seller area" do
    let(:seller) { create(:named_seller) }

    include_context "with user signed in as admin for seller"

    describe "GET index" do
      before do
        @membership1 = create(:subscription_product, user: seller)
        @membership2 = create(:subscription_product, user: seller)
        @unpublished_membership = create(:subscription_product, user: seller, purchase_disabled_at: Time.current)
        @other_membership = create(:subscription_product)

        @product1 = create(:product, user: seller)
        @product2 = create(:product, user: seller)
        @unpublished_product = create(:product, user: seller, purchase_disabled_at: Time.current)
        @other_product = create(:product)
      end

      it_behaves_like "authorize called for action", :get, :index do
        let(:record) { Link }
      end

      it "returns seller's products" do
        get :index

        memberships = assigns(:memberships)
        expect(memberships).to include(@membership1)
        expect(memberships).to include(@membership2)
        expect(memberships).to include(@unpublished_membership)
        expect(memberships).to_not include(@other_membership)

        products = assigns(:products)
        expect(products).to include(@product1)
        expect(products).to include(@product2)
        expect(products).to include(@unpublished_product)
        expect(products).to_not include(@other_product)
      end

      it "does not return the deleted products" do
        @membership2.update!(deleted_at: Time.current)
        @product2.update!(deleted_at: Time.current)
        get :index

        expect(assigns(:memberships)).to_not include(@membership2)
        expect(assigns(:products)).to_not include(@product2)
      end

      it "does not return archived products" do
        @membership2.update!(archived: true)
        @product2.update!(archived: true)

        get :index

        expect(assigns(:memberships)).to_not include(@membership2)
        expect(assigns(:products)).to_not include(@product2)
      end

      describe "shows the correct number of sales" do
        def expect_sales_count_in_inertia_response(expected_count)
          products = inertia.props[:react_products_page_props][:products]
          expect(products).to be_present, "Expected products in Inertia.js response"
          expect(products.first[:successful_sales_count]).to eq(expected_count)
        end

        it "with a single sale" do
          allow_any_instance_of(Link).to receive(:successful_sales_count).and_return(1)

          get(:index)
          expect(response).to be_successful

          expect(inertia).to render_component("Products/Index")

          expect_sales_count_in_inertia_response(1)
        end

        it "with over a thousand sales, comma-delimited" do
          allow_any_instance_of(Link).to receive(:successful_sales_count).and_return(3_030)
          get(:index)
          expect(response).to be_successful

          expect(inertia).to render_component("Products/Index")

          expect_sales_count_in_inertia_response(3_030)
        end

        it "shows comma-delimited pre-orders count" do
          @product1.update_attribute(:is_in_preorder_state, true)
          allow_any_instance_of(Link).to receive(:successful_sales_count).and_return(424_242)
          get(:index)
          expect(response).to be_successful

          expect(inertia).to render_component("Products/Index")

          expect_sales_count_in_inertia_response(424_242)
        end

        it "shows comma-delimited subscribers count" do
          create(:subscription_product, user: seller)
          allow_any_instance_of(Link).to receive(:successful_sales_count).and_return(1_111)
          get(:index)
          expect(response).to be_successful

          expect(inertia).to render_component("Products/Index")

          expect_sales_count_in_inertia_response(1_111)
        end
      end

      describe "visible product URLs" do
        it "shows product URL without the protocol part" do
          get :index

          expect(response).to be_successful

          expect(inertia).to render_component("Products/Index")

          products = inertia.props[:react_products_page_props][:products]
          expect(products).to be_present
          expect(products.first[:url_without_protocol]).to be_present
        end
      end
    end

    describe "GET memberships_paged" do
      before do
        @memberships_per_page = 2
        stub_const("LinksController::PER_PAGE", @memberships_per_page)
      end

      it_behaves_like "authorize called for action", :get, :memberships_paged do
        let(:record) { Link }
        let(:policy_method) { :index? }
      end

      describe "membership sorting + pagination", :elasticsearch_wait_for_refresh do
        include_context "with products and memberships"

        it_behaves_like "an API for sorting and pagination", :memberships_paged do
          let!(:default_order) { [membership2, membership3, membership4, membership1] }
          let!(:columns) do
            {
              "name" => [membership1, membership2, membership3, membership4],
              "successful_sales_count" => [membership4, membership1, membership3, membership2],
              "revenue" => [membership4, membership1, membership3, membership2],
              "display_price_cents" => [membership4, membership3, membership2, membership1]
            }
          end
          let!(:boolean_columns) { { "status" => [membership3, membership4, membership2, membership1] } }
        end
      end

      describe "more than 2n visible memberships" do
        before do
          @memberships_count = 2 * @memberships_per_page + 1
          @memberships_count.times { create(:subscription_product, user: seller) }
        end

        it "returns success on page 1" do
          get :memberships_paged, params: { page: 1 }
          expect(response.parsed_body["entries"].length).to eq @memberships_per_page
        end

        it "returns success on page 2" do
          get :memberships_paged, params: { page: 2 }
          expect(response.parsed_body["entries"].length).to eq @memberships_per_page
        end

        it "returns success on page 3" do
          get :memberships_paged, params: { page: 3 }
          expect(response.parsed_body["entries"].length).to eq 1
        end
      end

      describe "between n and 2n visible memberships" do
        before do
          @memberships_count = @memberships_per_page + 1
          @memberships_count.times { create(:subscription_product, user: seller) }
        end

        it "returns correctly on page 1" do
          get :memberships_paged, params: { page: 1 }
          expect(response.parsed_body["entries"].length).to eq @memberships_per_page
        end

        it "returns correctly on page 2" do
          get :memberships_paged, params: { page: 2 }
          expect(response.parsed_body["entries"].length).to eq 1
        end

        it "raises on page overflow" do
          expect { get :memberships_paged, params: { page: 3 } }.to raise_error(Pagy::OverflowError)
        end

        describe "has some deleted memberships" do
          before do
            3.times { create(:subscription_product, user: seller, deleted_at: Time.current) }
          end

          it "returns correctly on page 1" do
            get :memberships_paged, params: { page: 1 }
            expect(response.parsed_body["entries"].length).to eq @memberships_per_page
          end

          it "returns correctly on page 2" do
            get :memberships_paged, params: { page: 2 }
            expect(response.parsed_body["entries"].length).to eq 1
          end

          it "raises on page overflow" do
            expect { get :memberships_paged, params: { page: 3 } }.to raise_error(Pagy::OverflowError)
          end
        end
      end

      describe "< n visible memberships" do
        before do
          @published_count = @memberships_per_page - 1
          @published_count.times { create(:subscription_product, user: seller) }
        end

        it "returns correctly on page 1" do
          get :memberships_paged, params: { page: 1 }
          expect(response.parsed_body["entries"].length).to eq @memberships_per_page - 1
        end

        it "raises on page overflow" do
          expect { get :memberships_paged, params: { page: 2 } }.to raise_error(Pagy::OverflowError)
        end
      end
    end

    describe "GET products_paged" do
      before do
        @products_per_page = 2
        stub_const("LinksController::PER_PAGE", @products_per_page)
      end

      it_behaves_like "authorize called for action", :get, :products_paged do
        let(:record) { Link }
        let(:policy_method) { :index? }
      end

      describe "non-membership sorting + pagination", :elasticsearch_wait_for_refresh do
        include_context "with products and memberships"

        it_behaves_like "an API for sorting and pagination", :products_paged do
          let!(:default_order) { [product1, product3, product4, product2] }
          let!(:columns) do
            {
              "name" => [product1, product2, product3, product4],
              "successful_sales_count" => [product1, product2, product3, product4],
              "revenue" => [product3, product2, product1, product4],
              "display_price_cents" => [product3, product4, product2, product1]
            }
          end
          let!(:boolean_columns) { { "status" => [product3, product4, product1, product2] } }
        end
      end

      describe "more than 2n visible products" do
        before do
          @products_count = 2 * @products_per_page + 1
          @products_count.times { create(:product, user: seller) }
        end

        it "returns success on page 1" do
          get :products_paged, params: { page: 1 }
          expect(response.parsed_body["entries"].length).to eq @products_per_page
        end

        it "returns success on page 2" do
          get :products_paged, params: { page: 2 }
          expect(response.parsed_body["entries"].length).to eq @products_per_page
        end

        it "returns success on page 3" do
          get :products_paged, params: { page: 3 }
          expect(response.parsed_body["entries"].length).to eq 1
        end
      end

      describe "between n and 2n visible products" do
        before do
          @products_count = @products_per_page + 1
          @products_count.times { create(:product, user: seller) }
        end

        it "returns correctly on page 1" do
          get :products_paged, params: { page: 1 }
          expect(response.parsed_body["entries"].length).to eq @products_per_page
        end

        it "returns correctly on page 2" do
          get :products_paged, params: { page: 2 }
          expect(response.parsed_body["entries"].length).to eq 1
        end

        it "raises on page overflow" do
          expect { get :products_paged, params: { page: 3 } }.to raise_error(Pagy::OverflowError)
        end

        describe "has some deleted products" do
          before do
            3.times { create(:product, user: seller, deleted_at: Time.current) }
          end

          it "returns correctly on page 1" do
            get :products_paged, params: { page: 1 }
            expect(response.parsed_body["entries"].length).to eq @products_per_page
          end

          it "returns correctly on page 2" do
            get :products_paged, params: { page: 2 }
            expect(response.parsed_body["entries"].length).to eq 1
          end

          it "raises on page overflow" do
            expect { get :products_paged, params: { page: 3 } }.to raise_error(Pagy::OverflowError)
          end
        end
      end

      describe "< n visible products" do
        before do
          @published_count = @products_per_page - 1
          @published_count.times { create(:product, user: seller) }
        end

        it "returns correctly on page 1" do
          get :products_paged, params: { page: 1 }
          expect(response.parsed_body["entries"].length).to eq @products_per_page - 1
        end

        it "raises on page overflow" do
          expect { get :products_paged, params: { page: 2 } }.to raise_error(Pagy::OverflowError)
        end
      end
    end

    %w[edit unpublish publish destroy].each do |action|
      describe "##{action}" do
        e404_test(action.to_sym)
      end
    end

    describe "POST publish" do
      before do
        @disabled_link = create(:physical_product, purchase_disabled_at: Time.current, user: seller)
      end

      it_behaves_like "authorize called for action", :post, :publish do
        let(:record) { @disabled_link }
        let(:request_params) { { id: @disabled_link.unique_permalink } }
      end

      it_behaves_like "collaborator can access", :post, :publish do
        let(:product) { @disabled_link }
        let(:request_params) { { id: @disabled_link.unique_permalink } }
        let(:response_attributes) { { "success" => true } }
      end

      it "enables a disabled link" do
        post :publish, params: { id: @disabled_link.unique_permalink }

        expect(response.parsed_body["success"]).to eq(true)
        expect(@disabled_link.reload.purchase_disabled_at).to be_nil
      end

      context "when link is not publishable" do
        before do
          allow_any_instance_of(Link).to receive(:publishable?) { false }
        end

        it "returns an error message" do
          post :publish, params: { id: @disabled_link.unique_permalink }

          expect(response.parsed_body["error_message"]).to eq("You must connect at least one payment method before you can publish this product for sale.")
        end

        it "does not publish the link" do
          post :publish, params: { id: @disabled_link.unique_permalink }

          expect(response.parsed_body["success"]).to eq(false)
          expect(@disabled_link.reload.purchase_disabled_at).to be_present
        end
      end

      context "when user email is not confirmed" do
        before do
          seller.update!(confirmed_at: nil)
          @unpublished_product = create(:physical_product, purchase_disabled_at: Time.current, user: seller)
        end

        it "returns an error message" do
          post :publish, params: { id: @unpublished_product.unique_permalink }
          expect(response.parsed_body["error_message"]).to eq("You have to confirm your email address before you can do that.")
        end

        it "does not publish the link" do
          post :publish, params: { id: @unpublished_product.unique_permalink }

          expect(response.parsed_body["success"]).to eq(false)
          expect(@unpublished_product.reload.purchase_disabled_at).to be_present
        end
      end

      context "when an unknown exception is raised" do
        before do
          allow_any_instance_of(Link).to receive(:publish!).and_raise("error")
        end

        it "sends a Bugsnag notification" do
          expect(Bugsnag).to receive(:notify).once

          post :publish, params: { id: @disabled_link.unique_permalink }
        end

        it "returns an error message" do
          post :publish, params: { id: @disabled_link.unique_permalink }

          expect(response.parsed_body["error_message"]).to eq("Something broke. We're looking into what happened. Sorry about this!")
        end

        it "does not publish the link" do
          post :publish, params: { id: @disabled_link.unique_permalink }

          expect(response.parsed_body["success"]).to eq(false)
          expect(@disabled_link.reload.purchase_disabled_at).to be_present
        end
      end
    end

    describe "POST unpublish" do
      it_behaves_like "collaborator can access", :post, :unpublish do
        let(:product) { create(:product, user: seller) }
        let(:request_params) { { id: product.unique_permalink } }
        let(:response_attributes) { { "success" => true } }
      end
    end

    describe "PUT sections" do
      let(:product) { create(:product, user: seller) }
      it_behaves_like "authorize called for action", :put, :update_sections do
        let(:record) { product }
        let(:request_params) { { id: product.unique_permalink } }
      end

      it_behaves_like "collaborator can access", :put, :update_sections do
        let(:response_status) { 204 }
        let(:request_params) { { id: product.unique_permalink } }
      end

      it "updates the SellerProfileSections attached to the product and cleans up orphaned sections" do
        sections = create_list(:seller_profile_products_section, 2, seller:, product:)
        create(:seller_profile_posts_section, seller:, product:)
        create(:seller_profile_posts_section, seller:)

        put :update_sections, params: { id: product.unique_permalink, sections: sections.map(&:external_id), main_section_index: 1 }

        expect(product.reload).to have_attributes(sections: sections.map(&:id), main_section_index: 1)
        expect(seller.seller_profile_sections.count).to eq 3
        expect(seller.seller_profile_sections.on_profile.count).to eq 1
      end
    end

    describe "DELETE destroy" do
      describe "suspended tos violation user" do
        before do
          @admin_user = create(:user)
          @product = create(:product, user: seller)

          seller.flag_for_tos_violation(author_id: @admin_user.id, product_id: @product.id)
          seller.suspend_for_tos_violation(author_id: @admin_user.id)

          # NOTE: The invalidate_active_sessions! callback from suspending the user, interferes
          # with the login mechanism, this is a hack get the `sign_in user` method work correctly
          request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i
        end

        it_behaves_like "authorize called for action", :delete, :destroy do
          let(:record) { @product }
          let(:request_params) { { id: @product.unique_permalink } }
        end

        it "allows deletion if user suspended (tos)" do
          delete :destroy, params: { id: @product.unique_permalink }
          expect(@product.reload.deleted_at.present?).to be(true)
        end
      end
    end

    describe "GET edit" do
      let(:product) { create(:product, user: seller) }

      it_behaves_like "authorize called for action", :get, :edit do
        let(:record) { product }
        let(:request_params) { { id: product.unique_permalink } }
      end

      it "assigns the correct instance variables" do
        get :edit, params: { id: product.unique_permalink }
        expect(response).to be_successful

        product_presenter = assigns(:presenter)
        expect(product_presenter.product).to eq(product)
        expect(product_presenter.pundit_user).to eq(controller.pundit_user)
      end

      context "with other user not owning the product" do
        let(:other_user) { create(:user) }

        before do
          sign_in other_user
        end

        it "redirects to product page" do
          get :edit, params: { id: product.unique_permalink }
          expect(response).to redirect_to(short_link_path(product))
        end
      end

      context "with admin user signed in" do
        let(:admin) { create(:admin_user) }

        before do
          sign_in admin
        end

        it "renders the page" do
          get :edit, params: { id: product.unique_permalink }
          expect(response).to have_http_status(:ok)
        end
      end

      context "when the product is a bundle" do
        let(:bundle) { create(:product, :bundle) }

        it "redirects to the bundle edit page" do
          sign_in bundle.user
          get :edit, params: { id: bundle.unique_permalink }
          expect(response).to redirect_to(bundle_path(bundle.external_id))
        end
      end
    end

    describe "PUT update" do
      before do
        @product = create(:product_with_pdf_file, user: seller)
        @gif_file = fixture_file_upload("test-small.gif", "image/gif")
        product_file = @product.product_files.alive.first
        @params = {
          id: @product.unique_permalink,
          name: "sumlink",
          description: "New description",
          custom_button_text_option: "pay_prompt",
          custom_summary: "summary",
          custom_attributes: [
            {
              name: "name",
              value: "value"
            },
          ],
          file_attributes: [
            {
              name: "Length",
              value: "10 sections"
            }
          ],
          files: [
            {
              id: product_file.external_id,
              url: product_file.url
            }
          ],
          product_refund_policy_enabled: true,
          refund_policy: {
            max_refund_period_in_days: 7,
            fine_print: "Sample fine print",
          },
        }
      end

      it_behaves_like "authorize called for action", :put, :update do
        let(:record) { @product }
        let(:request_params) { @params }
      end

      it_behaves_like "collaborator can access", :put, :update do
        let(:product) { @product }
        let(:request_params) { @params }
        let(:response_status) { 204 }
      end

      context "when user email is empty" do
        before do
          seller.email = ""
          seller.save(validate: false)
        end

        it "includes error_message when publishing" do
          post :publish, params: { id: @product.unique_permalink }
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["error_message"]).to eq("<span>To publish a product, we need you to have an email. <a href=\"#{settings_main_url}\">Set an email</a> to continue.</span>")
        end
      end

      describe "licenses" do
        context "when license key is embedded in the product-level rich content" do
          it "sets is_licensed to true" do
            expect(@product.is_licensed).to be(false)

            post :update, params: @params.merge({ rich_content: [{ id: nil, title: "Page title", description: { type: "doc", content: [{ "type" => "licenseKey" }] } }] }), format: :json

            expect(@product.reload.is_licensed).to be(true)
          end
        end

        context "when license key is embedded in the rich content of at least one version" do
          it "sets is_licensed to true" do
            category = create(:variant_category, link: @product, title: "Versions")
            version1 = create(:variant, variant_category: category, name: "Version 1")
            version2 = create(:variant, variant_category: category, name: "Version 2")
            version1_rich_content1 = create(:rich_content, entity: version1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
            version1_rich_content1_updated_description = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Hello" }] }, { type: "licenseKey" }] }
            version2_new_rich_content_description = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Newly added version 2 content" }] }] }

            expect(@product.is_licensed).to be(false)

            post :update, params: @params.merge({
                                                  variants: [
                                                    { id: version1.external_id, name: version1.name, rich_content: [{ id: version1_rich_content1.external_id, title: "Version 1 - Page 1", description: version1_rich_content1_updated_description }] },
                                                    { id: version2.external_id, name: version2.name, rich_content: [{ id: nil, title: "Version 2 - Page 1", description: version2_new_rich_content_description }] }]
                                                }), format: :json

            expect(@product.reload.is_licensed).to be(true)
          end
        end

        it "sets is_licensed to false when no license key is embedded in the rich content" do
          expect(@product.is_licensed).to be(false)

          post :update, params: @params.merge({
                                                rich_content: [{ id: nil, title: "Page title", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Hello" }] }] } }]
                                              }), format: :json

          expect(@product.reload.is_licensed).to be(false)
        end
      end

      describe "coffee products" do
        it "sets suggested_price_cents to the maximum price_difference_cents of variants" do
          coffee_product = create(:coffee_product)
          sign_in coffee_product.user

          post :update, params: {
            id: coffee_product.unique_permalink,
            variants: [
              { price_difference_cents: 300 },
              { price_difference_cents: 500 },
              { price_difference_cents: 100 }
            ]
          }, as: :json

          expect(response).to be_successful
          expect(coffee_product.reload.suggested_price_cents).to eq(500)
        end
      end

      describe "content_updated_at" do
        it "is updated when a new file is uploaded" do
          freeze_time do
            url = "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png"
            post(:update, params: @params.merge!(files: [{ id: SecureRandom.uuid, url: }]), format: :json)

            @product.reload
            expect(@product.content_updated_at).to eq Time.current
          end
        end
        it "is not updated when irrelevant attributes are changed" do
          freeze_time do
            post(:update, params: @params.merge(description: "new description"), format: :json)

            expect(response).to be_successful
            @product.reload
            expect(@product.content_updated_at).to be_nil
          end
        end
      end

      describe "invalidate_action" do
        before do
          Rails.cache.write("views/#{@product.cache_key_prefix}_en_displayed_switch_ids_.html", "<html>hello</html>")
        end

        it "invalidates the action" do
          expect(Rails.cache.read("views/#{@product.cache_key_prefix}_en_displayed_switch_ids_.html")).to_not be_nil
          post :update, params: @params.merge({ id: @product.unique_permalink })
          expect(Rails.cache.read("views/#{@product.cache_key_prefix}_en_displayed_switch_ids_.html")).to be_nil
        end
      end

      it "updates the product" do
        expect(SaveContentUpsellsService).to receive(:new).with(
          seller: @product.user,
          content: "New description",
          old_content: "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes.",
        ).and_call_original

        put :update, params: @params, as: :json

        expect(@product.reload.name).to eq "sumlink"
        expect(@product.custom_button_text_option).to eq "pay_prompt"
        expect(@product.custom_summary).to eq "summary"
        expect(@product.custom_attributes).to eq [{ "name" => "name", "value" => "value" }]
        expect(@product.removed_file_info_attributes).to eq [:Size]
        expect(@product.product_refund_policy_enabled).to be(false)
        expect(@product.product_refund_policy).to be_nil
      end

      context "when seller_refund_policy_disabled_for_all feature flag is set to true" do
        before do
          Feature.activate(:seller_refund_policy_disabled_for_all)
        end

        it "updates the product refund policy" do
          put :update, params: @params, as: :json
          @product.reload
          expect(@product.product_refund_policy_enabled).to be(true)
          expect(@product.product_refund_policy.title).to eq("7-day money back guarantee")
          expect(@product.product_refund_policy.fine_print).to eq("Sample fine print")
        end
      end

      context "when seller refund policy is set to false" do
        before do
          @product.user.update!(refund_policy_enabled: false)
        end

        it "updates the product refund policy" do
          put :update, params: @params, as: :json
          @product.reload
          expect(@product.product_refund_policy_enabled).to be(true)
          expect(@product.product_refund_policy.title).to eq "7-day money back guarantee"
          expect(@product.product_refund_policy.fine_print).to eq "Sample fine print"
        end

        context "with product refund policy enabled" do
          before do
            @product.update!(product_refund_policy_enabled: true)
          end

          it "disables the product refund policy" do
            @params[:product_refund_policy_enabled] = false
            put :update, params: @params, as: :json
            @product.reload
            expect(@product.product_refund_policy_enabled).to be(false)
            expect(@product.product_refund_policy).to be_nil
          end
        end
      end

      it "updates a physical product" do
        product = create(:physical_product, user: seller, skus_enabled: true)
        shipping_destination = product.shipping_destinations.first
        post :update, params: {
          id: product.unique_permalink,
          name: "physical",
          shipping_destinations: [
            {
              id: shipping_destination.id,
              country_code: shipping_destination.country_code,
              one_item_rate_cents: shipping_destination.one_item_rate_cents,
              multiple_items_rate_cents: shipping_destination.multiple_items_rate_cents
            }
          ]
        }
        expect(response).to be_successful
        product.reload
        expect(product.name).to eq "physical"
        expect(product.skus_enabled).to be(false)
      end

      it "appends removed_file_info_attributes when additional keys are provided" do
        put :update, params: @params.merge({ file_attributes: [] }), format: :json
        expect(@product.reload.removed_file_info_attributes).to eq %i[Size Length]
      end

      describe "currency and price updates" do
        before do
          @product.update!(price_currency_type: "usd", price_cents: 1000)
        end

        it "changes product from USD $10 to EUR €12 and back to USD $11" do
          expect(@product.price_currency_type).to eq "usd"
          expect(@product.price_cents).to eq 1000

          put :update, params: {
            id: @product.unique_permalink,
            price_currency_type: "eur",
            price_cents: 1200
          }, as: :json

          expect(response).to be_successful
          @product.reload
          expect(@product.price_currency_type).to eq "eur"
          expect(@product.price_cents).to eq 1200

          put :update, params: {
            id: @product.unique_permalink,
            price_currency_type: "usd",
            price_cents: 1100
          }, as: :json

          expect(response).to be_successful
          @product.reload
          expect(@product.price_currency_type).to eq "usd"
          expect(@product.price_cents).to eq 1100
        end
      end

      it "sets the correct value for removed_file_info_attributes if there are none" do
        post :update, params: @params.merge({
                                              file_attributes: [
                                                {
                                                  name: "Length",
                                                  value: "10 sections"
                                                },
                                                {
                                                  name: "Size",
                                                  value: "100 TB"
                                                }
                                              ]
                                            }), format: :json
        expect(@product.reload.removed_file_info_attributes).to eq []
      end

      it "deletes custom attributes" do
        post :update, params: @params.merge(custom_attributes: []), format: :json
        expect(@product.reload.custom_attributes).to eq []
      end

      it "ignores custom attributes with both blank name and blank value" do
        post :update, params: @params.merge(custom_attributes: [{ name: "", value: "" }]), format: :json
        expect(@product.reload.custom_attributes).to eq []
      end

      it "marks the product as adult if the is_adult param is true" do
        post :update, params: @params.merge(is_adult: true), format: :json
        expect(@product.reload.is_adult).to be(true)
      end

      it "marks the product as non-adult if the is_adult param is false" do
        @product.update!(is_adult: true)
        post :update, params: @params.merge(is_adult: false), format: :json
        expect(@product.reload.is_adult).to be(false)
      end

      it "marks the product as allowing display of reviews if the display_product_reviews param is true" do
        post :update, params: @params.merge(display_product_reviews: true), format: :json
        expect(@product.reload.display_product_reviews).to be(true)
      end

      it "marks the product as not allowing display of reviews if the display_product_reviews param is false" do
        @product.update!(display_product_reviews: true)
        post :update, params: @params.merge(display_product_reviews: false), format: :json
        expect(@product.reload.display_product_reviews).to be(false)
      end

      it "marks the product as allowing display of sales count if the should_show_sales_count param is true" do
        post :update, params: @params.merge(should_show_sales_count: true), format: :json
        expect(@product.reload.should_show_sales_count).to be(true)
      end

      it "marks the product as not allowing display of sales count if the should_show_sales_count param is false" do
        @product.update!(should_show_sales_count: true)
        post :update, params: @params.merge(should_show_sales_count: false), format: :json
        expect(@product.reload.should_show_sales_count).to be(false)
      end

      describe "adding variants" do
        describe "variants" do
          it "adds variants to the product" do
            variants = [
              { name: "red", price_difference_cents: 400, max_purchase_count: 100 },
              { name: "blue", price_difference_cents: 300 }
            ]
            post :update, params: { id: @product.unique_permalink, variants: }, as: :json

            variant1 = @product.alive_variants.first
            expect(variant1.name).to eq("red")
            expect(variant1.price_difference_cents).to eq(400)
            expect(variant1.max_purchase_count).to eq(100)
            variant2 = @product.alive_variants.second
            expect(variant2.name).to eq("blue")
            expect(variant2.price_difference_cents).to eq(300)
            expect(variant2.max_purchase_count).to eq(nil)
          end
        end

        describe "removing a variant from an existing category" do
          let(:category) { create(:variant_category, title: "sizes", link: @product) }
          let!(:variant1) { create(:variant, variant_category: category, name: "small", price_difference_cents: 200, max_purchase_count: 100) }

          let!(:variant2) { create(:variant, variant_category: category, name: "medium", price_difference_cents: 300) }
          it "persists the variants correctly" do
            variants = [
              { name: "small", id: variant1.external_id, price_difference_cents: 200, max_purchase_count: 100 }
            ]
            post :update, params: { id: @product.unique_permalink, variants: }, as: :json

            expect(@product.reload.variant_categories.count).to eq(1)
            expect(@product.alive_variants.count).to eq(1)

            expect(variant1.reload).to be_alive
            expect(variant1.name).to eq("small")
            expect(variant1.price_difference_cents).to eq(200)
            expect(variant1.max_purchase_count).to eq(100)
            expect(variant2.reload).to be_deleted
          end
        end

        context "when all variants are removed" do
          let(:category) { create(:variant_category, title: "sizes", link: @product) }
          let!(:variant1) { create(:variant, variant_category: category, name: "small", price_difference_cents: 200, max_purchase_count: 100) }

          it "removes the category" do
            expect do
              post :update, params: { id: @product.unique_permalink, variants: [] }, as: :json
            end.to change { @product.reload.variant_categories_alive.count }.from(1).to(0)
          end
        end
      end

      it "updates profile sections" do
        product1 = create(:product, user: seller)
        product2 = create(:product, user: seller)
        section1 = create(:seller_profile_products_section, seller:, shown_products: [product1, product2].map(&:id))
        section2 = create(:seller_profile_products_section, seller:, shown_products: [product1.id])
        section3 = create(:seller_profile_products_section, seller:, shown_products: [product2.id])
        params = {
          id: product1.unique_permalink,
          section_ids: [section3.external_id],
        }
        put :update, params:, format: :json
        expect(section1.reload.shown_products).to eq [product2.id]
        expect(section2.reload.shown_products).to eq []
        expect(section3.reload.shown_products).to eq [product2, product1].map(&:id)

        put :update, params: params.merge({ section_ids: [] }), format: :json
        expect(section1.reload.shown_products).to eq [product2.id]
        expect(section2.reload.shown_products).to eq []
        expect(section3.reload.shown_products).to eq [product2.id]
      end

      describe "subscription pricing" do
        let(:membership_product) { create(:membership_product, user: seller) }

        context "changing membership price update settings for a tier" do
          let(:tier) { membership_product.default_tier }
          let(:disabled_params) do
            {
              id: membership_product.unique_permalink,
              variants: [
                {
                  id: tier.external_id,
                  name: tier.name,
                  apply_price_changes_to_existing_memberships: false,
                }
              ]
            }
          end
          let(:effective_date) { 10.days.from_now.to_date }
          let(:enabled_params) do
            params = disabled_params
            params[:variants][0][:apply_price_changes_to_existing_memberships] = true
            params[:variants][0][:subscription_price_change_effective_date] = effective_date.strftime("%Y-%m-%d")
            params[:variants][0][:subscription_price_change_message] = "hello"
            params
          end

          it "enables existing membership price upgrades" do
            post :update, params: enabled_params

            tier.reload
            expect(tier.apply_price_changes_to_existing_memberships).to eq true
            expect(tier.subscription_price_change_effective_date).to eq effective_date
            expect(tier.subscription_price_change_message).to eq "hello"
          end

          context "when existing membership price upgrades are enabled" do
            before do
              tier.update!(apply_price_changes_to_existing_memberships: true,
                           subscription_price_change_effective_date: effective_date,
                           subscription_price_change_message: "hello")
            end

            it "changes effective date to a later date and schedules emails to subscribers" do
              new_effective_date = 1.month.from_now.to_date
              enabled_params[:variants][0][:subscription_price_change_effective_date] = new_effective_date.strftime("%Y-%m-%d")

              post :update, params: enabled_params

              expect(tier.reload.subscription_price_change_effective_date).to eq new_effective_date
              expect(ScheduleMembershipPriceUpdatesJob).to have_enqueued_sidekiq_job(tier.id)
            end

            it "changes effective date to an earlier date and schedules emails to subscribers" do
              new_effective_date = 7.days.from_now.to_date
              enabled_params[:variants][0][:subscription_price_change_effective_date] = new_effective_date.strftime("%Y-%m-%d")

              post :update, params: enabled_params

              expect(tier.reload.subscription_price_change_effective_date).to eq new_effective_date
              expect(ScheduleMembershipPriceUpdatesJob).to have_enqueued_sidekiq_job(tier.id)
            end

            it "disables them" do
              post :update, params: disabled_params, as: :json

              tier.reload
              expect(tier.apply_price_changes_to_existing_memberships).to eq false
              expect(tier.subscription_price_change_effective_date).to be_nil
              expect(tier.subscription_price_change_message).to be_nil
              expect(ScheduleMembershipPriceUpdatesJob).not_to have_enqueued_sidekiq_job(tier.id)
            end
          end
        end
      end

      describe "setting recurring prices on a variant" do
        before :each do
          @product = create(:membership_product, user: seller)
          @tier_category = @product.tier_category

          @params.delete(:files)
          @params.merge!(
            id: @product.unique_permalink,
            variants: [
              {
                name: "First Tier",
                recurrence_price_values: {
                  monthly: {
                    enabled: true,
                    price_cents: 2000
                  },
                  quarterly: {
                    enabled: true,
                    price_cents: 4500
                  },
                  yearly: {
                    enabled: true,
                    price_cents: 12000
                  },
                  biannually: { enabled: false },
                  every_two_years: {
                    enabled: true,
                    price_cents: 20000
                  }
                },
              },
              {
                name: "Second Tier",
                recurrence_price_values: {
                  monthly: {
                    enabled: true,
                    price_cents: 1000
                  },
                  quarterly: {
                    enabled: true,
                    price_cents: 2500
                  },
                  yearly: {
                    enabled: true,
                    price_cents: 6000
                  },
                  biannually: { enabled: false },
                  every_two_years: {
                    enabled: true,
                    price_cents: 10000
                  }
                }
              }
            ]
          )
        end

        it "sets the prices on the variants" do
          post :update, params: @params, format: :json

          variants = @tier_category.reload.variants

          first_tier_prices = variants.find_by!(name: "First Tier").prices
          second_tier_prices = variants.find_by!(name: "Second Tier").prices

          expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).price_cents).to eq 2000
          expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).price_cents).to eq 4500
          expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).price_cents).to eq 12000
          expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS).price_cents).to eq 20000
          expect(first_tier_prices.find_by(recurrence: BasePrice::Recurrence::BIANNUALLY)).to be nil

          expect(second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).price_cents).to eq 1000
          expect(second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).price_cents).to eq 2500
          expect(second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).price_cents).to eq 6000
          expect(second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS).price_cents).to eq 10000
          expect(second_tier_prices.find_by(recurrence: BasePrice::Recurrence::BIANNUALLY)).to be nil
        end

        describe "cancellation discounts" do
          before do
            @params[:cancellation_discount] = ActionController::Parameters.new(
              discount: ActionController::Parameters.new(
                type: "fixed",
                cents: "100"
              ).permit!,
              duration_in_billing_cycles: "3"
            ).permit!
          end

          context "when cancellation_discounts feature flag is off" do
            it "does not update the cancellation discount" do
              expect(Product::SaveCancellationDiscountService).not_to receive(:new)
              post :update, params: @params, format: :json
            end
          end

          context "when cancellation_discounts feature flag is on" do
            before do
              Feature.activate_user(:cancellation_discounts, @product.user)
            end

            it "updates the cancellation discount" do
              expect(Product::SaveCancellationDiscountService).to receive(:new).with(@product, @params[:cancellation_discount]).and_call_original
              post :update, params: @params, format: :json
            end
          end
        end

        context "with pay-what-you-want pricing" do
          it "sets the suggested prices" do
            @params.merge!(
              id: @product.unique_permalink,
              variants: [
                {
                  name: "First Tier",
                  customizable_price: true,
                  recurrence_price_values: {
                    monthly: {
                      enabled: true,
                      price_cents: 2000,
                      suggested_price_cents: 2200
                    },
                    quarterly: {
                      enabled: true,
                      price_cents: 4500,
                      suggested_price_cents: 4700
                    },
                    yearly: {
                      enabled: true,
                      price_cents: 12000,
                      suggested_price_cents: 12200
                    },
                    biannually: { enabled: false },
                    every_two_years: {
                      enabled: true,
                      price_cents: 20000,
                      suggested_price_cents: 21000
                    }
                  }
                }
              ]
            )

            post :update, params: @params, format: :json

            first_tier = @tier_category.reload.variants.find_by(name: "First Tier")
            first_tier_prices = first_tier.prices

            expect(first_tier.customizable_price).to be true
            expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).suggested_price_cents).to eq 2200
            expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).suggested_price_cents).to eq 4700
            expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).suggested_price_cents).to eq 12200
            expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS).suggested_price_cents).to eq 21000
          end
        end
      end

      describe "shipping" do
        before do
          @product.is_physical = true
          @product.require_shipping = true
          @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)
          @product.save!
        end

        it "sets the shipping rates as configured with no duplicates on the product" do
          post :update, params: {
            id: @product.unique_permalink,
            shipping_destinations: [
              { country_code: "US", one_item_rate_cents: 1200, multiple_items_rate_cents: 600 },
              { country_code: "DE", one_item_rate_cents: 1000, multiple_items_rate_cents: 500 }
            ]
          }, format: :json

          expect(response).to be_successful
          expect(@product.reload.shipping_destinations.alive.size).to eq(2)

          expect(@product.shipping_destinations.alive.first.country_code).to eq("US")
          expect(@product.shipping_destinations.alive.first.one_item_rate_cents).to eq(1200)
          expect(@product.shipping_destinations.alive.first.multiple_items_rate_cents).to eq(600)

          expect(@product.shipping_destinations.alive.second.country_code).to eq("DE")
          expect(@product.shipping_destinations.alive.second.one_item_rate_cents).to eq(1000)
          expect(@product.shipping_destinations.alive.second.multiple_items_rate_cents).to eq(500)
        end

        it "does not accept duplicate submission for the same country for a product" do
          post :update, params: {
            id: @product.unique_permalink,
            shipping_destinations: [
              { country_code: "US", one_item_rate_cents: 1200, multiple_items_rate_cents: 600 },
              { country_code: "US", one_item_rate_cents: 1000, multiple_items_rate_cents: 500 }
            ]
          }, format: :json

          expect(response).not_to be_successful
          expect(response.parsed_body["error_message"]).to eq("Sorry, shipping destinations have to be unique.")
        end

        it "does not allow link to be saved if there are no shipping destinations" do
          post :update, params: {
            id: @product.unique_permalink,
            shipping_destinations: []
          }, format: :json

          expect(response).not_to be_successful
          expect(response.parsed_body["error_message"]).to eq("The product needs to be shippable to at least one destination.")
          expect(@product.reload.shipping_destinations.alive.size).to eq(1)
        end

        describe "virtual countries" do
          it "sets the shipping rates as configured with no duplicates on the product" do
            post :update, params: {
              id: @product.unique_permalink,
              shipping_destinations: [
                { country_code: "EUROPE", one_item_rate_cents: 1200, multiple_items_rate_cents: 600 },
                { country_code: "ASIA", one_item_rate_cents: 1000, multiple_items_rate_cents: 500 }
              ]
            }, format: :json

            expect(response).to be_successful
            expect(@product.reload.shipping_destinations.alive.size).to eq(2)

            expect(@product.shipping_destinations.alive.first.country_code).to eq("EUROPE")
            expect(@product.shipping_destinations.alive.first.one_item_rate_cents).to eq(1200)
            expect(@product.shipping_destinations.alive.first.multiple_items_rate_cents).to eq(600)

            expect(@product.shipping_destinations.alive.second.country_code).to eq("ASIA")
            expect(@product.shipping_destinations.alive.second.one_item_rate_cents).to eq(1000)
            expect(@product.shipping_destinations.alive.second.multiple_items_rate_cents).to eq(500)
          end

          it "does not accept duplicate submission for the same country for a product" do
            post :update, params: {
              id: @product.unique_permalink,
              shipping_destinations: [
                { country_code: "EUROPE", one_item_rate_cents: 1200, multiple_items_rate_cents: 600 },
                { country_code: "EUROPE", one_item_rate_cents: 1000, multiple_items_rate_cents: 500 }
              ]
            }, format: :json

            expect(response).not_to be_successful
            expect(response.parsed_body["error_message"]).to eq("Sorry, shipping destinations have to be unique.")
          end
        end
      end

      describe "Tags and Categories" do
        describe "Adding tags" do
          let(:tags) { ["some sort of tàg!", "tagme", "🐗🐗"] }

          it "adds tags when there are none" do
            expect do
              post(:update, params: { id: @product.unique_permalink, tags: })
            end.to change { Tag.count }.by(3)
            expect(@product.tags.pluck(:name)).to eq(tags)
          end

          it "adds tags when they exist" do
            create(:tag, name: "tagme")
            @product.tag!("🐗🐗")
            expect do
              post(:update, params: { id: @product.unique_permalink, tags: })
            end.to change { Tag.count }.by(1)
            expect(@product.reload.tags.length).to eq(3)
            expect(@product.has_tag?("some sort of tàg!")).to be(true)
          end

          it "removes all tags" do
            @product.tag!("one tag")
            @product.tag!("another tag")
            expect do
              post(:update, params: { id: @product.unique_permalink, tags: [] })
            end.to change { @product.reload.tags.length }.from(2).to(0)
          end

          it "does not remove tags if unchanged" do
            @product.tag!("one tag")
            @product.tag!("another tag")
            expect do
              post(:update, params: { id: @product.unique_permalink, tags: @product.tags.pluck(:name) })
            end.to_not change { @product.reload.tags.length }
            expect(@product.tags.pluck(:name)).to eq(["one tag", "another tag"])
          end
        end
      end

      describe "custom attributes" do
        it "saves the custom attributes properly" do
          custom_attributes = [{ name: "author", value: "amir" }, { name: "chapters", value: "2" }]
          post :update, params: {
            id: @product.unique_permalink,
            custom_attributes:
          }
          expect(@product.reload.custom_attributes).to eq custom_attributes.as_json
        end
      end

      describe "without files" do
        it "allows updating a published product to have no files" do
          expect do
            post :update, params: { id: @product.unique_permalink, files: [] }, format: :json
            # Initialzing a new object instead of using @product.alive_product_file.count to
            # prevent reading cached value
          end.to change { Link.find(@product.id).alive_product_files.count }.from(1).to(0)
          expect(response).to be_successful
        end
      end

      describe "public files" do
        let(:public_file1) { create(:public_file, :with_audio, resource: @product, display_name: "Audio 1") }
        let(:public_file2) { create(:public_file, :with_audio, resource: @product, display_name: "Audio 2") }
        let(:description) do
          <<~HTML
            <p>Some text</p>
            <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
            <p>Hello world!</p>
            <public-file-embed id="#{public_file2.public_id}"></public-file-embed>
            <p>More text</p>
          HTML
        end

        before do
          @product.update!(description:)
        end

        it "updates existing files and the product description appropriately" do
          files_params = [
            { "id" => public_file1.public_id, "name" => "Updated Audio 1", "status" => { "type" => "saved" } },
            { "id" => public_file2.public_id, "name" => "Updated Audio 2", "status" => { "type" => "saved" } },
            { "id" => "blob:http://example.com/audio.mp3", "name" => "Audio 3", "status" => { "type" => "uploading" } }
          ]

          post :update, params: { id: @product.unique_permalink, description:, public_files: files_params }, format: :json

          expect(response).to be_successful
          expect(public_file1.reload.attributes.values_at("display_name", "scheduled_for_deletion_at")).to eq(["Updated Audio 1", nil])
          expect(public_file2.reload.attributes.values_at("display_name", "scheduled_for_deletion_at")).to eq(["Updated Audio 2", nil])
          expect(@product.public_files.alive.count).to eq(2)
          expect(@product.reload.description).to eq(description)
        end

        it "schedules unused files for deletion" do
          unused_file = create(:public_file, :with_audio, resource: @product)
          files_params = [
            { "id" => public_file1.public_id, "name" => "Audio 1", "status" => { "type" => "saved" } }
          ]

          post :update, params: { id: @product.unique_permalink, description:, public_files: files_params }, format: :json

          expect(response).to be_successful
          expect(@product.public_files.alive.count).to eq(3)
          expect(@product.reload.description).to include(public_file1.public_id)
          expect(@product.description).to_not include(public_file2.public_id)
          expect(@product.description).to_not include(unused_file.public_id)
          expect(unused_file.reload.scheduled_for_deletion_at).to be_within(5.seconds).of(10.days.from_now)
          expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
          expect(public_file2.reload.scheduled_for_deletion_at).to be_within(5.seconds).of(10.days.from_now)
        end

        it "removes invalid file embeds from content" do
          content_with_invalid_embeds = <<~HTML
            <p>Some text</p>
            <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
            <p>Middle text</p>
            <public-file-embed id="nonexistent"></public-file-embed>
            <public-file-embed></public-file-embed>
            <p>More text</p>
          HTML
          files_params = [
            { "id" => public_file1.public_id, "name" => "Audio 1", "status" => { "type" => "saved" } },
            { "id" => public_file2.public_id, "name" => "Audio 2", "status" => { "type" => "saved" } },
          ]

          post :update, params: { id: @product.unique_permalink, description: content_with_invalid_embeds, public_files: files_params }, format: :json

          expect(response).to be_successful
          expect(@product.reload.description).to eq(<<~HTML
            <p>Some text</p>
            <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
            <p>Middle text</p>


            <p>More text</p>
          HTML
          )
          expect(@product.public_files.alive.count).to eq(2)
          expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
          expect(public_file2.reload.scheduled_for_deletion_at).to be_within(5.seconds).of(10.days.from_now)
        end

        it "handles missing public_files params" do
          post :update, params: { id: @product.unique_permalink, description: }, format: :json

          expect(response).to be_successful
          expect(@product.reload.description).to eq(<<~HTML
            <p>Some text</p>

            <p>Hello world!</p>

            <p>More text</p>
          HTML
          )
          expect(public_file1.reload.scheduled_for_deletion_at).to be_present
          expect(public_file2.reload.scheduled_for_deletion_at).to be_present
        end

        it "handles empty description" do
          files_params = [
            { "id" => public_file1.public_id, "status" => { "type" => "saved" } }
          ]

          post :update, params: { id: @product.unique_permalink, description: "", public_files: files_params }, format: :json

          expect(response).to be_successful
          expect(@product.reload.description).to eq("")
          expect(public_file1.reload.scheduled_for_deletion_at).to be_present
          expect(public_file2.reload.scheduled_for_deletion_at).to be_present
        end

        it "rolls back on error" do
          files_params = [
            { "id" => public_file1.public_id, "name" => "Updated Audio 1", "status" => { "type" => "saved" } }
          ]
          allow_any_instance_of(PublicFile).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(public_file1))

          post :update, params: { id: @product.unique_permalink, description:, public_files: files_params }, format: :json

          expect(response).not_to be_successful
          expect(public_file1.reload.display_name).to eq("Audio 1")
          expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
          expect(public_file2.reload.scheduled_for_deletion_at).to be_nil
          expect(@product.reload.description).to eq(description)
        end
      end

      describe "multiple files" do
        def files_data_from_urls(urls)
          urls.map { { id: SecureRandom.uuid, url: _1 } }
        end

        it "preserves correct s3 key for s3 files containing percent and ampersand" do
          urls = ["https://s3.amazonaws.com/gumroad-specs/specs/test file %26 & ) %29.txt"]
          post :update, params: @params.merge!(files: files_data_from_urls(urls)), format: :json
          expect(response).to be_successful
          product_file = @product.alive_product_files.first
          expect(product_file.s3_key).to eq "specs/test file %26 & ) %29.txt"
        end

        it "saves the files properly" do
          urls = ["https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png",
                  "https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf"]
          post :update, params: @params.merge!(files: files_data_from_urls(urls)), format: :json
          expect(response).to be_successful
          expect(@product.alive_product_files.count).to eq 2
          expect(@product.alive_product_files[0].url).to eq "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png"
          expect(@product.alive_product_files[1].url).to eq "https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf"
        end

        it "has pdf filetype" do
          urls = ["https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png",
                  "https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf"]
          post :update, params: @params.merge!(files: files_data_from_urls(urls)), format: :json
          expect(@product.has_filetype?("pdf")).to be(true)
        end

        it "supports deleting and adding files" do
          @product.product_files << create(:product_file, link: @product, url: "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png")
          @product.save!

          urls = ["https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf"]
          post :update, params: @params.merge!(files: files_data_from_urls(urls)), format: :json
          expect(response).to be_successful
          expect(@product.reload.alive_product_files.count).to eq 1
          expect(@product.alive_product_files.first.url).to eq "https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf"
        end

        it "allows 0 files for unpublished product" do
          @product.purchase_disabled_at = Time.current
          @product.product_files << create(:product_file, link: @product, url: "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png")
          @product.save!

          post :update, params: @params.merge!(files: {}), format: :json
          expect(response).to be_successful
        end

        it "updates product's rich content when file embed IDs exist in product_rich_content" do
          urls = %w[https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf]
          files_data = files_data_from_urls(urls)
          rich_content = create(:product_rich_content, entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
          old_rich_content = rich_content.description
          product_rich_content = [{ id: rich_content.external_id, title: "Page title", description: { type: "doc", content: old_rich_content.dup.concat([{ "type" => "fileEmbed", "attrs" => { "id" => files_data[0][:id], "uid" => "64e84875-c795-567c-d2dd-96336ab093d5" } }, { "type" => "fileEmbed", "attrs" => { "id" => files_data[1][:id], "uid" => "0c042930-2df1-4583-82ef-a6317213868d" } }]) } }]

          post :update, params: @params.merge!(rich_content: product_rich_content, files: files_data), format: :json

          new_external_id_1, new_external_id_2 = @product.product_files.alive.map(&:external_id)
          expect(@product.reload.rich_content_json).to eq([{ id: rich_content.external_id, page_id: rich_content.external_id, variant_id: nil, title: "Page title", description: { type: "doc", content: old_rich_content.dup.concat([{ "type" => "fileEmbed", "attrs" => { "id" => new_external_id_1, "uid" => "64e84875-c795-567c-d2dd-96336ab093d5" } }, { "type" => "fileEmbed", "attrs" => { "id" => new_external_id_2, "uid" => "0c042930-2df1-4583-82ef-a6317213868d" } }]) }, updated_at: rich_content.reload.updated_at }])
        end

        it "saves variant-level rich content containing file embeds with the persisted IDs" do
          external_id1 = "ext1"
          external_id2 = "ext2"
          category = create(:variant_category, link: @product, title: "Versions")
          version1 = create(:variant, variant_category: category, name: "Version 1")
          version2 = create(:variant, variant_category: category, name: "Version 2")
          version1_rich_content1 = create(:rich_content, entity: version1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
          version1_rich_content2 = create(:rich_content, entity: version1, deleted_at: 1.day.ago)
          version1_rich_content3 = create(:rich_content, entity: version1)
          another_product_version_rich_content = create(:rich_content, entity: create(:variant))
          version1_rich_content1_updated_description = [{ "type" => "fileEmbed", "attrs" => { "id" => external_id1, "uid" => "64e84875-c795-567c-d2dd-96336ab093d5" } }, { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }]
          version1_new_rich_content_description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newly added version 1 content" }] }]
          version2_new_rich_content_description = [{ "type" => "fileEmbed", "attrs" => { "id" => external_id2, "uid" => "0c042930-2df1-4583-82ef-a6317213868d" } }]

          post :update, params: @params.merge!(
            files: [{ id: external_id1, url: "https://s3.amazonaws.com/gumroad-specs/attachment/#{external_id1}/original/pencil.png" }, { id: external_id2, url: "https://s3.amazonaws.com/gumroad-specs/attachment/#{external_id2}/original/manual.pdf" }],
            variants: [{ id: version1.external_id, name: version1.name, rich_content: [{ id: version1_rich_content1.external_id, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content1_updated_description } }, { id: nil, title: "Version 1 - Page 2", description: { type: "doc", content: version1_new_rich_content_description } }] }, { id: version2.external_id, name: version2.name, rich_content: [{ id: nil, title: "Version 2 - Page 1", description: { type: "doc", content: version2_new_rich_content_description } }] }]
          ), format: :json

          expect(version1_rich_content1.reload.deleted?).to be(false)
          expect(version1_rich_content2.reload.deleted?).to be(true)
          expect(version1_rich_content3.reload.deleted?).to be(true)
          expect(version1.rich_contents.count).to eq(4)
          expect(version1.alive_rich_contents.count).to eq(2)
          version1_new_rich_content = version1.alive_rich_contents.last
          expect(version1_new_rich_content.description).to eq(version1_new_rich_content_description)
          expect(version2.rich_contents.count).to eq(1)
          expect(version2.alive_rich_contents.count).to eq(1)
          expect(another_product_version_rich_content.reload.deleted?).to be(false)
        end

        it "calls SaveContentUpsellsService when rich content or description changes" do
          rich_content = create(:product_rich_content, entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Original content" }] }])
          product_rich_content = [{ id: rich_content.external_id, title: "Page title", description: { type: "doc", content: [{ "type" => "paragraph", "content": [{ "type" => "text", "text" => "New content" }] }] } }]

          expect(SaveContentUpsellsService).to receive(:new).with(
            seller: @product.user,
            content: "New description",
            old_content: "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes."
          ).and_call_original

          expect(SaveContentUpsellsService).to receive(:new).with(
            seller: @product.user,
            content: [
              ActionController::Parameters.new(
                {
                  "type" => "paragraph",
                  "content" => [
                    ActionController::Parameters.new(
                      {
                        "type" => "text",
                        "text" => "New content"
                      }).permit!
                  ]
                }
              ).permit!
            ],
            old_content: [
              {
                "type" => "paragraph",
                "content" => [
                  {
                    "type" => "text",
                    "text" => "Original content"
                  }
                ]
              }
            ]
          ).and_call_original

          post :update, params: @params.merge(rich_content: product_rich_content), format: :json
          expect(response).to be_successful
        end

        it "saves the product file thumbnails" do
          product_file1 = create(:streamable_video, link: @product)
          product_file2 = create(:readable_document, link: @product)
          @product.product_files << product_file1
          @product.product_files << product_file2
          blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"), filename: "smilie.png")
          blob.analyze
          files_data = [{ id: product_file1.external_id, url: product_file1.url, thumbnail: { signed_id: blob.signed_id } }, { id: product_file2.external_id, url: product_file2.url }]

          expect do
            post :update, params: @params.merge!(files: files_data), format: :json
          end.to change { product_file1.reload.thumbnail.blob }.from(nil).to(blob)

          expect(product_file2.reload.thumbnail.blob).to be_nil
          expect(response).to be_successful

          expect do
            post :update, params: { id: @product.unique_permalink, link: @params.merge!(files: files_data), format: :json }
          end.not_to change { product_file1.reload.thumbnail.blob }
        end
      end

      describe "adding integrations" do
        shared_examples "manages integrations" do
          it "adds a new integration" do
            expect do
              post :update, params: @params.merge(
                integrations: { integration_name => new_integration_params }
              ), as: :json
            end.to change { Integration.count }.by(1)
              .and change { ProductIntegration.count }.by(1)

            product_integration = ProductIntegration.last
            integration = Integration.last

            expect(product_integration.integration).to eq(integration)
            expect(product_integration.product).to eq(@product)
            expect(integration.type).to eq(Integration.type_for(integration_name))

            new_integration_params.merge(new_integration_params.delete("integration_details")).each do |key, value|
              expect(integration.send(key)).to eq(value)
            end
          end

          it "modifies an existing integration" do
            @product.active_integrations << create("#{integration_name}_integration".to_sym)

            expect do
              post :update, params: @params.merge(
                integrations: { integration_name => modified_integration_params }
              ), as: :json
            end.to change { Integration.count }.by(0)
              .and change { ProductIntegration.count }.by(0)

            product_integration = ProductIntegration.last
            integration = Integration.last

            expect(product_integration.integration).to eq(integration)
            expect(product_integration.product).to eq(@product)
            expect(integration.type).to eq(Integration.type_for(integration_name))
            modified_integration_params.merge(modified_integration_params.delete("integration_details")).each do |key, value|
              expect(integration.send(key)).to eq(value)
            end
          end

          context "variants" do
            it "adds a new integration" do
              expect do
                post :update, params: @params.merge(
                  integrations: { integration_name => new_integration_params },
                  variants: [
                    {
                      name: "PC",
                      price_difference_cents: 100,
                      max_purchase_count: 100,
                    },
                    {
                      name: "Mac",
                      price_difference_cents: 10000,
                      max_purchase_count: 100,
                      integrations: {
                        integration_name => true
                      },
                    },
                  ]
                ), as: :json
              end.to change { Integration.count }.by(1)
                .and change { ProductIntegration.count }.by(1)
                .and change { BaseVariantIntegration.count }.by(1)

              base_variant_integration = BaseVariantIntegration.last
              product_integration = ProductIntegration.last
              integration = Integration.last

              mac_variant = @product.alive_variants.find_by(name: "mac")

              expect(product_integration.integration).to eq(integration)
              expect(base_variant_integration.integration).to eq(integration)
              expect(base_variant_integration.base_variant).to eq(mac_variant)
              expect(mac_variant.active_integrations.count).to eq(1)
              expect(product_integration.product).to eq(@product)
              expect(integration.type).to eq(Integration.type_for(integration_name))
              new_integration_params.merge(new_integration_params.delete("integration_details")).each do |key, value|
                expect(integration.send(key)).to eq(value)
              end
            end

            it "modifies an existing integration" do
              category = create(:variant_category, title: "versions", link: @product)
              variant_1 = create(:variant, variant_category: category, name: "pc")
              integration = create("#{integration_name}_integration".to_sym)
              variant_2 = create(:variant, variant_category: category, name: "mac", active_integrations: [integration])
              @product.active_integrations << integration

              expect do
                post :update, params: @params.merge(
                  integrations: { integration_name => modified_integration_params },
                  variants: [
                    {
                      id: variant_1.external_id,
                      name: variant_1.name,
                      price_difference_cents: 1000,
                      max_purchase_count: 100,
                    },
                    {
                      id: variant_2.external_id,
                      name: variant_2.name,
                      price_difference_cents: 10000,
                      integrations: {
                        integration_name => true
                      },
                    },
                    {
                      name: "linux",
                      price_difference_cents: 0,
                      integrations: {
                        integration_name => true
                      },
                    },
                  ]
                ), as: :json
              end.to change { Integration.count }.by(0)
                .and change { ProductIntegration.count }.by(0)
                .and change { BaseVariantIntegration.count }.by(1)

              base_variant_integrations = BaseVariantIntegration.all[-2, 2]
              product_integration = ProductIntegration.last

              integration.reload

              expect(product_integration.integration).to eq(integration)

              expect(base_variant_integrations[0].integration).to eq(integration)
              expect(base_variant_integrations[0].base_variant).to eq(@product.variant_categories_alive.find_by(title: "versions").alive_variants.find_by(name: "mac"))

              expect(base_variant_integrations[1].integration).to eq(integration)
              expect(base_variant_integrations[1].base_variant).to eq(@product.variant_categories_alive.find_by(title: "versions").alive_variants.find_by(name: "linux"))

              expect(product_integration.product).to eq(@product)
              expect(integration.type).to eq(Integration.type_for(integration_name))
              modified_integration_params.merge(modified_integration_params.delete("integration_details")).each do |key, value|
                expect(integration.send(key)).to eq(value)
              end
            end
          end
        end

        describe "circle integration" do
          let(:integration_name) { "circle" }
          let(:new_integration_params) do
            {
              "api_key" => GlobalConfig.get("CIRCLE_API_KEY"),
              "keep_inactive_members" => false,
              "integration_details" => { "community_id" => "0", "space_group_id" => "0" }
            }
          end
          let(:modified_integration_params) do
            {
              "api_key" => "modified_api_key",
              "keep_inactive_members" => true,
              "integration_details" => { "community_id" => "1", "space_group_id" => "1" }
            }
          end

          it_behaves_like "manages integrations"
        end

        describe "discord integration" do
          let(:server_id) { "0" }
          let(:integration_name) { "discord" }
          let(:new_integration_params) do
            {
              "keep_inactive_members" => false,
              "integration_details" => { "server_id" => server_id, "server_name" => "Gaming", "username" => "gumbot" }
            }
          end
          let(:modified_integration_params) do
            {
              "keep_inactive_members" => true,
              "integration_details" => { "server_id" => "1", "server_name" => "Tech", "username" => "techuser" }
            }
          end

          it_behaves_like "manages integrations"

          describe "disconnection" do
            let(:request_header) { { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" } }
            let!(:discord_integration) do
              integration = create(:discord_integration, server_id:)
              @product.active_integrations << integration
              integration
            end

            it "succeeds if bot is successfully removed from server" do
              WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
                with(headers: request_header).
                to_return(status: 204)

              expect do
                post :update, params: { id: @product.unique_permalink, link: @params.merge(integrations: {}) }, as: :json
              end.to change { @product.active_integrations.count }.by(-1)

              expect(@product.live_product_integrations.pluck(:integration_id)).to match_array []
            end

            it "fails if removing bot from server fails" do
              WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
                with(headers: request_header).
                to_return(status: 404, body: { code: Discordrb::Errors::UnknownMember.code }.to_json)

              expect do
                post :update, params: { id: @product.unique_permalink, link: @params.merge(integrations: {}) }, as: :json
              end.to change { @product.active_integrations.count }.by(0)

              expect(@product.live_product_integrations.pluck(:integration_id)).to match_array [discord_integration.id]
              expect(response.parsed_body["error_message"]).to eq("Could not disconnect the discord integration, please try again.")
            end
          end
        end

        describe "zoom integration" do
          let(:integration_name) { "zoom" }
          let(:new_integration_params) do
            {
              "keep_inactive_members" => false,
              "integration_details" => { "user_id" => "0", "email" => "test@zoom.com", "access_token" => "test_access_token", "refresh_token" => "test_refresh_token" }
            }
          end
          let(:modified_integration_params) do
            {
              "keep_inactive_members" => true,
              "integration_details" => { "user_id" => "1", "email" => "test2@zoom.com", "access_token" => "modified_access_token", "refresh_token" => "modified_refresh_token" }
            }
          end

          it_behaves_like "manages integrations"
        end

        describe "google calendar integration" do
          let(:integration_name) { "google_calendar" }
          let(:new_integration_params) do
            {
              "keep_inactive_members" => false,
              "integration_details" => { "calendar_id" => "0", "calendar_summary" => "Holidays", "access_token" => "test_access_token", "refresh_token" => "test_refresh_token" }
            }
          end
          let(:modified_integration_params) do
            {
              "keep_inactive_members" => true,
              "integration_details" => { "calendar_id" => "1", "calendar_summary" => "Meetings", "access_token" => "modified_access_token", "refresh_token" => "modified_refresh_token" }
            }
          end

          it_behaves_like "manages integrations"

          describe "disconnection" do
            let!(:google_calendar_integration) do
              integration = create(:google_calendar_integration)
              @product.active_integrations << integration
              integration
            end

            it "succeeds if the gumroad app is successfully disconnected from google account" do
              WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/revoke").
                with(query: { token: google_calendar_integration.access_token }).to_return(status: 200)

              expect do
                post :update, params: { id: @product.unique_permalink, link: @params.merge(integrations: {}) }, as: :json
              end.to change { @product.active_integrations.count }.by(-1)

              expect(@product.live_product_integrations.pluck(:integration_id)).to match_array []
            end

            it "fails if disconnecting the gumroad app from google fails" do
              WebMock.stub_request(:post, "#{GoogleCalendarApi::GOOGLE_CALENDAR_OAUTH_URL}/revoke").
                with(query: { token: google_calendar_integration.access_token }).to_return(status: 404)

              expect do
                post :update, params: { id: @product.unique_permalink, link: @params.merge(integrations: {}) }, as: :json
              end.to change { @product.active_integrations.count }.by(0)

              expect(@product.live_product_integrations.pluck(:integration_id)).to match_array [google_calendar_integration.id]
              expect(response.parsed_body["error_message"]).to eq("Could not disconnect the google calendar integration, please try again.")
            end
          end
        end
      end

      describe "custom domains" do
        context "with an existing domain" do
          let(:new_domain_name) { "example2.com" }

          context "when product has an existing custom domain" do
            before do
              create(:custom_domain, user: nil, product: @product, domain: "example-domain.com")
            end

            it "updates the custom_domain" do
              expect do
                post(:update, params: @params.merge({ custom_domain: new_domain_name }), format: :json)
              end.to change {
                @product.reload.custom_domain.domain
              }.from("example-domain.com").to(new_domain_name)

              expect(response).to be_successful
            end

            context "when domain verification fails" do
              before do
                @product.custom_domain.update!(failed_verification_attempts_count: 2)

                allow_any_instance_of(CustomDomainVerificationService)
                  .to receive(:process)
                  .and_return(false)
              end

              it "does not increment the failed verification attempts count" do
                expect do
                  post(:update, params: @params.merge({ custom_domain: "invalid.example.com" }), format: :json)
                end.to_not change {
                  @product.reload.custom_domain.failed_verification_attempts_count
                }
              end
            end
          end

          context "when the product doesn't have an existing custom_domain" do
            it "creates a new custom_domain" do
              expect do
                post(:update, params: @params.merge({ custom_domain: new_domain_name }), format: :json)
              end.to change { CustomDomain.alive.count }.by(1)

              expect(@product.reload.custom_domain.domain).to eq new_domain_name
              expect(response).to be_successful
            end
          end
        end
      end

      it "enqueues a RenameProductFileWorker job" do
        @product.product_files << create(:product_file, link: @product, url: "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png")
        @product.save!
        post :update, params: {
          id: @product.unique_permalink,
          files: [
            {
              id: @product.product_files.last.external_id,
              display_name: "sample",
              description: "new description",
              url: @product.product_files.last.url,
            }
          ],
          rich_content: [],
        }
        expect(response).to be_successful
        product_file = @product.alive_product_files.last.reload

        expect(product_file.display_name).to eq("sample")
        expect(product_file.description).to eq("new description")
        expect(RenameProductFileWorker).to have_enqueued_sidekiq_job(product_file.id)
      end

      describe "rich content" do
        let(:product) { create(:product, user: seller) }
        let(:product_content) { [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }] }

        it "saves the rich content pages in the given order" do
          updated_rich_content1_description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }, { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "World" }] }]
          new_rich_content_description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Newly added" }] }]
          rich_content1 = create(:product_rich_content, title: "p1", position: 0, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
          rich_content2 = create(:product_rich_content, title: "p2", position: 1, entity: product, deleted_at: 1.day.ago)
          rich_content3 = create(:product_rich_content, title: "p3", position: 2, entity: product)
          rich_content4 = create(:product_rich_content, title: "p4", position: 3, entity: product)
          another_product_rich_content = create(:product_rich_content)

          expect(product.alive_rich_contents.sort_by(&:position).pluck(:title, :position)).to eq([["p1", 0], ["p3", 2], ["p4", 3]])

          post :update, params: {
            id: product.unique_permalink,
            rich_content: [
              {
                id: rich_content4.external_id,
                title: "Intro",
                description: {
                  type: "doc",
                  content: [{ "type" => "paragraph" }],
                },
              },
              {
                id: rich_content1.external_id,
                title: "Page 1",
                description: {
                  type: "doc",
                  content: updated_rich_content1_description,
                },
              },
              {
                title: "Page 2",
                description: {
                  type: "doc",
                  content: new_rich_content_description,
                },
              },
              {
                title: "Page 3",
                description: nil,
              },
            ],
          }, format: :json

          expect(rich_content1.reload.deleted?).to be(false)
          expect(rich_content1.description).to eq(updated_rich_content1_description)
          expect(rich_content2.reload.deleted?).to be(true)
          expect(rich_content3.reload.deleted?).to be(true)
          expect(rich_content4.reload.deleted?).to be(false)
          expect(another_product_rich_content.reload.deleted?).to be(false)
          expect(product.reload.rich_contents.count).to eq(6)
          expect(product.alive_rich_contents.count).to eq(4)
          new_rich_content = product.alive_rich_contents.second_to_last
          expect(new_rich_content.description).to eq(new_rich_content_description)
          expect(product.alive_rich_contents.sort_by(&:position).pluck(:title, :position)).to eq([["Intro", 0], ["Page 1", 1], ["Page 2", 2], ["Page 3", 3]])

          # Deletes all existing rich content pages if no rich content is passed
          expect do
            post :update, params: { id: product.unique_permalink, rich_content: [] }, format: :json
          end.to change { product.reload.alive_rich_contents.count }.from(4).to(0)
          .and change { product.rich_contents.count }.by(0)
        end
      end

      describe "product_files_archive generation" do
        it "deletes all product-level archives when switching to variant-level archives" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          @product.product_files = [file1, file2]
          folder1_id = SecureRandom.uuid
          description = [
            { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
            ] }
          ]
          files = [
            { id: file1.external_id, url: file1.url },
            { id: file2.external_id, url: file2.url }
          ]

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ title: "Page 1", description: { type: "doc", content: description } }],
              files:,
            }, format: :json
          end.to change { @product.product_files_archives.alive.count }.by(1)
          archives = @product.product_files_archives.alive.to_a
          archives.each do |archive|
            archive.mark_in_progress!
            archive.mark_ready!
          end

          # Do not delete/create any archives if no new changes have been made
          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [
                {
                  id: @product.alive_rich_contents.find_by(position: 0).external_id,
                  title: "Page 1",
                  description: { type: "doc", content: description, },
                }
              ],
              files:,
            }, format: :json
          end.to_not change { ProductFilesArchive.count }
          expect(archives.all?(&:alive?)).to eq(true)

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              has_same_rich_content_for_all_variants: false,
              variants: [
                {
                  name: "Version 1",
                  rich_content: [
                    {
                      title: "Version 1 - Page 1",
                      description: { type: "doc", content: description, }
                    }
                  ],
                }
              ],
              files:,
            }, format: :json
          end.to change { ProductFilesArchive.where.not(variant_id: nil).alive.count }.by(1)
          .and change { @product.product_files_archives.alive.count }.by(-1)
        end

        it "deletes all variant-level archives when switching to product-level archives" do
          category = create(:variant_category, link: @product, title: "Versions")
          version1 = create(:variant, variant_category: category, name: "Version 1")

          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          @product.product_files = [file1, file2]
          version1.product_files = [file1, file2]
          version1_rich_content_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }]

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              has_same_rich_content_for_all_variants: false,
              files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }],
              variants: [{ id: version1.external_id, name: version1.name, rich_content: [{ id: nil, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content_description, } }] }]
            }, format: :json
          end.to change { version1.product_files_archives.alive.count }.by(1)
          .and change { @product.product_files_archives.alive.count }.by(0)

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              has_same_rich_content_for_all_variants: true,
              rich_content: [{ id: nil, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content_description } }],
              files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }],
              variants: [{ id: version1.external_id, name: version1.name }]
            }, format: :json
          end.to change { version1.product_files_archives.alive.count }.by(-1)
          .and change { @product.product_files_archives.alive.count }.by(1)
        end

        it "does not generate a folder archive when nothing has changed" do
          expect { post :update, params: { id: @product.unique_permalink, name: @product.name }, format: :json }.to change { @product.product_files_archives.folder_archives.alive.count }.by(0)
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(0)
        end

        it "does not generate a folder archive when there are no folders" do
          file1 = create(:product_file, display_name: "File 1")
          @product.product_files = [file1]
          description = [{ "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => "file1" } }]

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
              files: [{ id: file1.external_id, url: file1.url }]
            }, format: :json
          end.to_not change { @product.product_files_archives.folder_archives.alive.count }
        end

        it "does not generate a folder archive when a folder only contains 1 file" do
          file1 = create(:product_file, display_name: "File 1")
          @product.product_files = [file1]
          description = [
            { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => SecureRandom.uuid }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } }] },
          ]

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
              files: [{ id: file1.external_id, url: file1.url }]
            }, format: :json
          end.to_not change { @product.product_files_archives.folder_archives.alive.count }
        end

        it "does not generate an updated folder archive when the product name or page name is changed" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          @product.product_files = [file1, file2]

          folder1_id = SecureRandom.uuid
          folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }


          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: [folder1] } }],
            files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }]
          }, format: :json

          folder1_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)
          folder1_archive.mark_in_progress!
          folder1_archive.mark_ready!

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              name: "New product name",
              rich_content: [{ id: nil, title: "New page title", description: { type: "doc", content: [folder1] } }],
              files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }],
            }, format: :json
          end.to_not change { @product.product_files_archives.folder_archives.alive.count }
          expect(folder1_archive.reload.alive?).to eq(true)
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(1)
          expect(@product.alive_rich_contents.first["title"]).to eq("New page title")
          expect(@product.reload.name).to eq("New product name")
        end

        it "does not generate an updated folder archive when top-level files are modified" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          file3 = create(:product_file, display_name: "File 2")
          file4 = create(:product_file, display_name: "File 2")
          @product.product_files = [file1, file2, file3, file4]
          folder1_id = SecureRandom.uuid
          page1_description = [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => "file1" } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => "file2" } },
            { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
            ] }]

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: page1_description } }],
              files: [file1, file2, file3, file4].map { { id: _1.external_id, url: _1.url } }
            }, format: :json
          end.to change { @product.product_files_archives.folder_archives.alive.count }.by(1)

          folder1_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)
          folder1_archive.mark_in_progress!
          folder1_archive.mark_ready!

          file2.update!(display_name: "New file name")
          file5 = create(:product_file, display_name: "File 3")
          @product.product_files << file5
          updated_description = [
            { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => "file2" } },
            { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
            ] },
            { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => "file5" } }]
          page1 = @product.alive_rich_contents.find_by(position: 0)

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: updated_description } }],
              files: [file2, file3, file4, file5].map { { id: _1.external_id, url: _1.url } }
            }, format: :json
          end.to_not change { @product.product_files_archives.folder_archives.alive.count }
          expect(folder1_archive.reload.alive?).to eq(true)

          new_description = @product.alive_rich_contents.first.description

          expect(new_description.any? { |node| node.dig("attrs", "id") == file1.external_id }).to eq(false)
          expect(new_description.any? { |node| node.dig("attrs", "id") == file2.external_id }).to eq(true)
          expect(new_description.any? { |node| node.dig("attrs", "id") == file5.external_id }).to eq(true)
        end

        it "generates a folder archive for every valid folder on a page" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          file3 = create(:product_file, display_name: "File 3")
          file4 = create(:product_file, display_name: "File 4")
          file5 = create(:product_file, display_name: "File 5")
          file6 = create(:product_file, display_name: "File 6")
          @product.product_files = [file1, file2, file3, file4, file5, file6]
          folder1_id = SecureRandom.uuid
          folder2_id = SecureRandom.uuid
          folder3_id = SecureRandom.uuid
          description = [
            { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder1_id }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
            ] },
            { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => folder2_id }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
            ] },
            { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => folder3_id }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file6.external_id, "uid" => SecureRandom.uuid } },
            ] }]

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
              files: [file1, file2, file3, file4, file5, file6].map { { id: _1.external_id, url: _1.url } }
            }, format: :json
          end.to change { @product.product_files_archives.folder_archives.alive.count }.by(3)

          folder1_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)
          folder1_archive.mark_in_progress!
          folder1_archive.mark_ready!
          expect(folder1_archive.digest).to eq(Digest::SHA1.hexdigest(["#{folder1_id}/folder 1/#{file1.external_id}/File 1", "#{folder1_id}/folder 1/#{file2.external_id}/File 2"].sort.join("\n")))
          expect(folder1_archive.url.split("/").last).to eq("folder_1.zip")

          folder2_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder2_id)
          folder2_archive.mark_in_progress!
          folder2_archive.mark_ready!
          expect(folder2_archive.digest).to eq(Digest::SHA1.hexdigest(["#{folder2_id}/folder 2/#{file3.external_id}/File 3", "#{folder2_id}/folder 2/#{file4.external_id}/File 4"].sort.join("\n")))
          expect(folder2_archive.url.split("/").last).to eq("folder_2.zip")

          folder3_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder3_id)
          folder3_archive.mark_in_progress!
          folder3_archive.mark_ready!
          expect(folder3_archive.digest).to eq(Digest::SHA1.hexdigest(["#{folder3_id}/Untitled 1/#{file5.external_id}/File 5", "#{folder3_id}/Untitled 1/#{file6.external_id}/File 6"].sort.join("\n")))
          expect(folder3_archive.url.split("/").last).to eq("Untitled.zip")

          # Do not delete/create any archives if no new changes have been made
          page1 = @product.alive_rich_contents.find_by(position: 0)
          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: page1.description } }],
              files: [file1, file2, file3, file4, file5, file6].map { { id: _1.external_id, url: _1.url } }
            }, format: :json
          end.to_not change { @product.product_files_archives.folder_archives.count }

          expect([folder1_archive.reload, folder2_archive.reload, folder3_archive.reload].all?(&:alive?)).to eq(true)
        end

        it "generates a folder archive when a folder is added to an existing page" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          @product.product_files = [file1, file2]
          folder1_id = SecureRandom.uuid
          folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "", "uid" => folder1_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: [folder1] } }],
              files: [file1, file2].map { { id: _1.external_id, url: _1.url } }
            }, format: :json
          end.to change { @product.product_files_archives.folder_archives.alive.count }.by(1)
          archive = @product.product_files_archives.folder_archives.alive.last
          archive.mark_in_progress!
          archive.mark_ready!
          expect(archive.digest).to eq(Digest::SHA1.hexdigest(["#{folder1_id}/Untitled 1/#{file1.external_id}/File 1", "#{folder1_id}/Untitled 1/#{file2.external_id}/File 2"].sort.join("\n")))
          expect(archive.url.split("/").last).to eq("Untitled.zip")

          folder2_id = SecureRandom.uuid

          page1 = @product.alive_rich_contents.find_by(position: 0)
          file3_id = SecureRandom.uuid
          file4_id = SecureRandom.uuid
          updated_page1_description = [folder1,
                                       { "type" => "fileEmbedGroup", "attrs" => { "name" => "Folder 2", "uid" => folder2_id }, "content" => [
                                         { "type" => "fileEmbed", "attrs" => { "id" => file3_id, "uid" => SecureRandom.uuid } },
                                         { "type" => "fileEmbed", "attrs" => { "id" => file4_id, "uid" => SecureRandom.uuid } },
                                       ] },
          ]
          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: updated_page1_description } }],
              files: [{ id: file1.external_id, url: file1.url }, { id: file2.external_id, url: file2.url }, { id: file3_id, display_name: "File 3", url: create(:product_file, display_name: "File 3").url }, { id: file4_id, display_name: "File 4", url: create(:product_file, display_name: "File 4").url }],
            }, format: :json
          end.to change { @product.product_files_archives.folder_archives.alive.count }.by(1)
          expect(archive.needs_updating?(@product.product_files)).to be(false)
          expect(archive.reload.alive?).to eq(true)
          expect(@product.product_files_archives.folder_archives.alive.count).to be(2)

          new_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.last
          new_archive.mark_in_progress!
          new_archive.mark_ready!

          file3 = @product.product_files.find_by(display_name: "File 3")
          file4 = @product.product_files.find_by(display_name: "File 4")
          expect(new_archive.digest).to eq(Digest::SHA1.hexdigest(["#{folder2_id}/Folder 2/#{file3.external_id}/File 3", "#{folder2_id}/Folder 2/#{file4.external_id}/File 4"].sort.join("\n")))
          expect(new_archive.url.split("/").last).to eq("Folder_2.zip")
        end

        it "generates a new folder archive and deletes the old archive for an existing folder that gets modified" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          @product.product_files = [file1, file2]
          folder1_id = SecureRandom.uuid
          folder1_name = "folder 1"
          folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => folder1_name, "uid" => folder1_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }
          description = [folder1]

          expect do
            post :update, params: {
              id: @product.unique_permalink,
              rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
              files: [file1, file2].map { { id: _1.external_id, url: _1.url } }
            }, format: :json
          end.to change { @product.product_files_archives.folder_archives.alive.count }.by(1)

          old_archive = @product.product_files_archives.folder_archives.alive.last
          old_archive.mark_in_progress!
          old_archive.mark_ready!

          expect(old_archive.digest).to eq(Digest::SHA1.hexdigest(["#{folder1_id}/#{folder1_name}/#{file1.external_id}/File 1", "#{folder1_id}/#{folder1_name}/#{file2.external_id}/File 2"].sort.join("\n")))
          expect(old_archive.url.split("/").last).to eq("folder_1.zip")

          folder1_name = "New folder name"
          folder1["attrs"]["name"] = folder1_name
          page1 = @product.alive_rich_contents.find_by(position: 0)

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: description } }],
            files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
          }, format: :json

          expect(old_archive.reload.alive?).to eq(false)
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(1)

          new_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.last
          new_archive.mark_in_progress!
          new_archive.mark_ready!

          expect(new_archive.digest).to eq(Digest::SHA1.hexdigest(["#{folder1_id}/#{folder1_name}/#{file1.external_id}/File 1", "#{folder1_id}/#{folder1_name}/#{file2.external_id}/File 2"].sort.join("\n")))
          expect(new_archive.url.split("/").last).to eq("New_folder_name.zip")
        end

        it "generates new folder archives when a file is moved from one folder to another folder" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          file3 = create(:product_file, display_name: "File 3")
          file4 = create(:product_file, display_name: "File 4")
          file5 = create(:product_file, display_name: "File 5")
          @product.product_files = [file1, file2, file3, file4, file5]

          folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }
          folder2 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 2", "uid" => SecureRandom.uuid }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
          ] }
          description = [folder1, folder2]

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
            files: [file1, file2, file3, file4, file5].map { { id: _1.external_id, url: _1.url } }
          }, format: :json

          folder1_archive = @product.product_files_archives.create!(folder_id: folder1.dig("attrs", "uid"))
          folder1_archive.product_files = @product.product_files
          folder1_archive.mark_in_progress!
          folder1_archive.mark_ready!

          folder2_archive = @product.product_files_archives.create!(folder_id: folder2.dig("attrs", "uid"))
          folder2_archive.product_files = @product.product_files
          folder2_archive.mark_in_progress!
          folder2_archive.mark_ready!

          new_folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => folder1.dig("attrs", "name"), "uid" => folder1.dig("attrs", "uid") }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
          ] }
          new_folder2 = { "type" => "fileEmbedGroup", "attrs" => { "name" => folder2.dig("attrs", "name"), "uid" => folder2.dig("attrs", "uid") }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
          ] }
          new_description = [new_folder1, new_folder2]
          page1 = @product.alive_rich_contents.find_by(position: 0)

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: new_description } }],
            files: [file1, file2, file3, file4, file5].map { { id: _1.external_id, url: _1.url } },
          }, format: :json

          expect(folder1_archive.reload.alive?).to eq(false)
          expect(folder2_archive.reload.alive?).to eq(false)
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(2)

          new_folder1_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: new_folder1.dig("attrs", "uid"))
          new_folder1_archive.mark_in_progress!
          new_folder1_archive.mark_ready!

          new_folder2_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: new_folder2.dig("attrs", "uid"))
          new_folder2_archive.mark_in_progress!
          new_folder2_archive.mark_ready!

          expect(new_folder1_archive.digest).to eq(Digest::SHA1.hexdigest(["#{new_folder1.dig("attrs", "uid")}/#{new_folder1.dig("attrs", "name")}/#{file1.external_id}/File 1", "#{new_folder1.dig("attrs", "uid")}/#{new_folder1.dig("attrs", "name")}/#{file2.external_id}/File 2", "#{new_folder1.dig("attrs", "uid")}/#{new_folder1.dig("attrs", "name")}/#{file3.external_id}/File 3"].sort.join("\n")))
          expect(new_folder2_archive.digest).to eq(Digest::SHA1.hexdigest(["#{new_folder2.dig("attrs", "uid")}/#{new_folder2.dig("attrs", "name")}/#{file4.external_id}/File 4", "#{new_folder2.dig("attrs", "uid")}/#{new_folder2.dig("attrs", "name")}/#{file5.external_id}/File 5"].sort.join("\n")))
        end

        it "deletes the corresponding folder archive when a folder gets deleted" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          @product.product_files = [file1, file2]
          folder_id = SecureRandom.uuid
          description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }]

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
            files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
          }, format: :json
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(1)

          old_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id:)
          old_archive.mark_in_progress!
          old_archive.mark_ready!

          new_description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }]
          page1 = @product.alive_rich_contents.find_by(position: 0)

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: new_description } }],
            files: [],
          }, format: :json

          expect(old_archive.reload.alive?).to eq(false)
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(0)
        end

        it "deletes a folder archive if the folder is updated to contain only 1 file" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          @product.product_files = [file1, file2]
          folder_id = SecureRandom.uuid
          description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }]

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: description } }],
            files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
          }, format: :json
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(1)

          old_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id:)
          old_archive.product_files = @product.product_files
          old_archive.mark_in_progress!
          old_archive.mark_ready!

          new_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }]
          page1 = @product.alive_rich_contents.find_by(position: 0)

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: new_description } }],
            files: [{ id: file1.external_id, url: file1.url }]
          }, format: :json

          expect(old_archive.reload.alive?).to eq(false)
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(0)
        end

        it "updates all folder archives when multiple changes occur to a product's rich content across multiple pages" do
          file1 = create(:product_file, display_name: "File 1")
          file2 = create(:product_file, display_name: "File 2")
          file3 = create(:product_file, display_name: "File 3")
          file4 = create(:product_file, display_name: "File 4")
          @product.product_files = [file1, file2, file3, file4]

          # Page 1 folder
          folder1_id = SecureRandom.uuid
          folder1_name = "folder 1"
          page1_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => folder1_name, "uid" => folder1_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
          ] }]

          # Page 2 folder
          folder2_id = SecureRandom.uuid
          folder2_name = "SECOND folder"
          page2_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => folder2_name, "uid" => folder2_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
          ] }]

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: page1_description } }, { id: nil, title: "Page 2", description: { type: "doc", content: page2_description } }],
            files: [file1, file2, file3, file4].map { { id: _1.external_id, url: _1.url } },
          }, format: :json

          folder1_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)
          folder1_archive.mark_in_progress!
          folder1_archive.mark_ready!

          folder2_archive = @product.product_files_archives.folder_archives.alive.find_by(folder_id: folder2_id)
          folder2_archive.mark_in_progress!
          folder2_archive.mark_ready!

          # Page 1 folder no longer needs an archive since it contains only one file embed
          updated_page1_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => folder1_name, "uid" => folder1_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          ] }]

          # Page 2 folder needs to replace its current archive with a new one since it contains a new file embed
          file5 = create(:product_file, display_name: "File 5")
          @product.product_files << file5
          updated_page2_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => folder2_name, "uid" => folder2_id }, "content" => [
            { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
          ] }]

          # Irrelevant rich content added to both pages
          updated_page1_description << { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ignore me" }] }
          updated_page2_description << { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "A paragraph" }] }

          page1 = @product.alive_rich_contents.find_by(position: 0)
          page2 = @product.alive_rich_contents.find_by(position: 1)

          post :update, params: {
            id: @product.unique_permalink,
            rich_content: [{ id: page1.external_id, title: page1.title, description: { type: "doc", content: updated_page1_description } }, { id: page2.external_id, title: page2.title, description: { type: "doc", content: updated_page2_description } }],
            files: [file1, file3, file4, file5].map { { id: _1.external_id, url: _1.url } },
          }, format: :json

          expect(folder1_archive.reload.alive?).to eq(false)
          expect(folder2_archive.reload.alive?).to eq(false)
          expect(@product.product_files_archives.folder_archives.alive.count).to eq(1)
          expect(@product.product_files_archives.folder_archives.alive.find_by(folder_id: folder1_id)).to be_nil

          new_folder2_archive = Link.find(@product.id).product_files_archives.folder_archives.alive.find_by(folder_id: folder2_id)
          new_folder2_archive.mark_in_progress!
          new_folder2_archive.mark_ready!
          expect(new_folder2_archive.digest).to eq(Digest::SHA1.hexdigest(["#{folder2_id}/#{folder2_name}/#{file3.external_id}/File 3", "#{folder2_id}/#{folder2_name}/#{file4.external_id}/File 4", "#{folder2_id}/#{folder2_name}/#{file5.external_id}/File 5"].sort.join("\n")))
        end

        context "product variants" do
          it "generates folder archives for a new variant when has_same_rich_content_for_all_variants is false" do
            category = create(:variant_category, link: @product, title: "Versions")
            version1 = create(:variant, variant_category: category, name: "Version 1")

            file1 = create(:product_file, display_name: "File 1")
            file2 = create(:product_file, display_name: "File 2")
            @product.product_files = [file1, file2]
            version1.product_files = [file1, file2]
            version1_rich_content_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
            ] }]

            expect do
              post :update, params: {
                id: @product.unique_permalink,
                has_same_rich_content_for_all_variants: false,
                files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
                variants: [{ id: version1.external_id, name: version1.name, rich_content: [{ id: nil, title: "Version 1 - Page 1", description: { type: "doc", content: version1_rich_content_description } }] }]
              }, format: :json
            end.to change { version1.product_files_archives.folder_archives.alive.count }.by(1)
            .and change { @product.product_files_archives.folder_archives.alive.count }.by(0)
          end

          it "generates folder archives for the file embed groups in product-level content when has_same_rich_content_for_all_variants is true" do
            file1 = create(:product_file, display_name: "File 1")
            file2 = create(:product_file, display_name: "File 2")
            @product.product_files = [file1, file2]
            variant_category = create(:variant_category, title: "versions", link: @product)
            variant = create(:variant, variant_category:, name: "mac")
            variant.product_files = [file1, file2]

            folder1 = { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
              { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
            ] }

            expect do
              post :update, params: {
                id: @product.unique_permalink,
                has_same_rich_content_for_all_variants: true,
                rich_content: [{ id: nil, title: "Page 1", description: { type: "doc", content: [folder1] } }],
                variants: [{ "id" => variant.external_id, "name" => "linux", "price" => "2" }],
                files: [file1, file2].map { { id: _1.external_id, url: _1.url } },
              }, format: :json
            end.to change { variant.product_files_archives.folder_archives.alive.count }.by(0)
            .and change { @product.product_files_archives.folder_archives.alive.count }.by(1)
          end
        end
      end

      describe "error handling on save" do
        context "when Link::LinkInvalid is raised" do
          let(:product) { create(:product, user: seller) }

          it "logs and renders error message" do
            allow_any_instance_of(Link).to receive(:save!).and_raise(Link::LinkInvalid)

            post :update, params: @params, as: :json

            expect(response).to have_http_status(:unprocessable_entity)
          end
        end
      end

      describe "installment plans" do
        context "when product is eligible for installment plans" do
          let(:product) { create(:product, user: seller, price_cents: 1000) }

          context "no existing plans" do
            it "creates a new plan" do
              expect do
                post :update, params: {
                  id: product.unique_permalink,
                  installment_plan: {
                    number_of_installments: 3,
                    recurrence: "monthly"
                  }
                }, as: :json
              end.to change { ProductInstallmentPlan.alive.count }.by(1)

              plan = product.reload.installment_plan
              expect(plan.number_of_installments).to eq(3)
              expect(plan.recurrence).to eq("monthly")
            end
          end

          context "updating an existing plan" do
            let!(:existing_plan) do
              create(
                :product_installment_plan,
                link: product,
                number_of_installments: 2,
                recurrence: "monthly"
              )
            end

            context "has existing payment_options" do
              before do
                create(:payment_option, installment_plan: existing_plan)
                create(:installment_plan_purchase, link: product)
              end

              it "soft deletes the existing plan and creates a new plan" do
                expect do
                  post :update, params: {
                    id: product.unique_permalink,
                    installment_plan: {
                      number_of_installments: 4,
                      recurrence: "monthly"
                    }
                  }, as: :json
                end.to change { existing_plan.reload.deleted_at }.from(nil)

                new_plan = product.reload.installment_plan
                expect(new_plan).to have_attributes(
                  number_of_installments: 4,
                  recurrence: "monthly"
                )
                expect(new_plan).not_to eq(existing_plan)

                expect do
                  post :update, params: {
                    id: product.unique_permalink,
                    installment_plan: {
                      number_of_installments: 4,
                      recurrence: "monthly"
                    }
                  }, as: :json
                end.not_to change { new_plan.reload.deleted_at }
                expect(product.reload.installment_plan).to eq(new_plan)
              end
            end

            context "no existing payment_options" do
              it "destroys the existing plan and creates a new plan" do
                expect do
                  post :update, params: {
                    id: product.unique_permalink,
                    installment_plan: {
                      number_of_installments: 4,
                      recurrence: "monthly"
                    }
                  }, as: :json
                end.not_to change { ProductInstallmentPlan.count }

                expect { existing_plan.reload }.to raise_error(ActiveRecord::RecordNotFound)
                new_plan = product.reload.installment_plan
                expect(new_plan).to have_attributes(
                  number_of_installments: 4,
                  recurrence: "monthly"
                )

                expect do
                  post :update, params: {
                    id: product.unique_permalink,
                    installment_plan: {
                      number_of_installments: 4,
                      recurrence: "monthly"
                    }
                  }, as: :json
                end.not_to change { new_plan.reload.deleted_at }
                expect(product.reload.installment_plan).to eq(new_plan)
              end
            end
          end

          context "removing an existing plan" do
            let!(:existing_plan) do
              create(
                :product_installment_plan,
                link: product,
                number_of_installments: 2,
                recurrence: "monthly"
              )
            end

            context "has existing payment_options" do
              before do
                create(:payment_option, installment_plan: existing_plan)
                create(:installment_plan_purchase, link: product)
              end

              it "soft deletes the existing plan even if product is no longer eligible for installment plans" do
                expect do
                  post :update, params: {
                    id: product.unique_permalink,
                    price_cents: 0,
                    installment_plan: nil
                  }, as: :json
                end.to change { existing_plan.reload.deleted_at }.from(nil)

                expect(product.reload.installment_plan).to be_nil
              end
            end

            context "no existing payment_options" do
              it "destroys the existing plan" do
                expect do
                  post :update, params: {
                    id: product.unique_permalink,
                    installment_plan: nil
                  }, as: :json
                end.to change { ProductInstallmentPlan.count }.by(-1)

                expect { existing_plan.reload }.to raise_error(ActiveRecord::RecordNotFound)
                expect(product.reload.installment_plan).to be_nil
              end
            end
          end
        end

        context "when product is not eligible for installment plans" do
          let(:membership_product) { create(:membership_product, user: seller) }

          it "does not create an installment plan" do
            expect do
              post :update, params: {
                id: membership_product.unique_permalink,
                installment_plan: {
                  number_of_installments: 3,
                  recurrence: "monthly"
                }
              }, as: :json
            end.not_to change { ProductInstallmentPlan.count }
          end
        end
      end

      describe "community chat" do
        context "when communities feature is enabled" do
          before do
            Feature.activate_user(:communities, seller)
          end

          it "enables community chat when requested" do
            post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json

            expect(response).to be_successful
            expect(@product.reload.community_chat_enabled?).to be(true)
            expect(@product.reload.active_community).to be_present
          end

          it "disables community chat when requested" do
            @product.update!(community_chat_enabled: true)

            post :update, params: { id: @product.unique_permalink, community_chat_enabled: false }, as: :json

            expect(response).to be_successful
            expect(@product.reload.community_chat_enabled?).to be(false)
            expect(@product.reload.active_community).to be_nil
          end

          it "does not enable community chat for coffee products" do
            seller.update!(created_at: (User::MIN_AGE_FOR_SERVICE_PRODUCTS + 1.day).ago)
            product = create(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE, price_cents: 1000)

            post :update, params: { id: product.unique_permalink, community_chat_enabled: true, variants: [{ price_difference_cents: 1000 }] }, as: :json
            expect(response).to be_successful
            expect(product.reload.community_chat_enabled?).to be(false)
            expect(product.reload.active_community).to be_nil
          end

          it "does not enable community chat for bundle products" do
            @product.update!(native_type: Link::NATIVE_TYPE_BUNDLE)

            post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json
            expect(response).to be_successful
            expect(@product.reload.community_chat_enabled?).to be(false)
            expect(@product.reload.active_community).to be_nil
          end

          it "reactivates existing community when enabling chat" do
            community = create(:community, resource: @product, seller: seller)
            community.mark_deleted!
            @product.update!(community_chat_enabled: false)

            post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json

            expect(response).to be_successful
            expect(@product.reload.community_chat_enabled?).to be(true)
            expect(community.reload).to be_alive
          end
        end

        context "when communities feature is disabled" do
          before do
            Feature.deactivate_user(:communities, seller)
          end

          it "does not enable community chat" do
            post :update, params: { id: @product.unique_permalink, community_chat_enabled: true }, as: :json

            expect(response).to be_successful
            expect(@product.reload.community_chat_enabled?).to be(false)
            expect(@product.reload.active_community).to be_nil
          end
        end
      end
    end

    describe "GET new" do
      it_behaves_like "authorize called for action", :get, :new do
        let(:record) { Link }
      end

      it "shows the introduction text if the user has no memberships or products" do
        get :new

        expect(response).to be_successful
        expect(assigns[:title]).to eq("What are you creating?")

        expect(inertia).to render_component("Products/New")

        expected_props = ProductPresenter.new_page_props(current_seller: seller)
        expected_props.each do |key, value|
          expect(inertia.props[key]).to eq(JSON.parse(value.to_json))
        end

        expect(inertia.props[:show_orientation_text]).to eq(true)
      end

      it "does not show the introduction text if the user has memberships" do
        create(:subscription_product, user: seller)
        get :new

        expect(response).to be_successful
        expect(assigns[:title]).to eq("What are you creating?")

        expect(inertia).to render_component("Products/New")

        expected_props = ProductPresenter.new_page_props(current_seller: seller)
        expected_props.each do |key, value|
          expect(inertia.props[key]).to eq(JSON.parse(value.to_json))
        end

        expect(inertia.props[:show_orientation_text]).to eq(false)
      end

      it "does not show the introduction text if the user has products" do
        create(:product, user: seller)
        get :new

        expect(response).to be_successful
        expect(assigns[:title]).to eq("What are you creating?")

        expect(inertia).to render_component("Products/New")

        expected_props = ProductPresenter.new_page_props(current_seller: seller)
        expected_props.each do |key, value|
          expect(inertia.props[key]).to eq(JSON.parse(value.to_json))
        end

        expect(inertia.props[:show_orientation_text]).to eq(false)
      end
    end

    describe "POST create" do
      before do
        Rails.cache.clear
      end

      it_behaves_like "authorize called for action", :post, :create do
        let(:record) { Link }
      end

      it "succeeds with name and price" do
        params = { price_cents: 100, name: "test link" }

        post :create, params: { format: :json, link: params }

        expect(response.parsed_body["success"]).to be(true)
      end

      it "fails if price missing" do
        params = { name: "test link" }
        post :create, params: { format: :json, link: params }
        expect(response.parsed_body["success"]).to_not be(true)
      end

      it "fails if name is missing" do
        params = { price_cents: 100 }
        post :create, params: { format: :json, link: params }
        expect(response.parsed_body["success"]).to be(false)
      end

      it "creates link with display_product_reviews set to true" do
        params = { price_cents: 100, name: "test link" }
        post :create, params: { format: :json, link: params }
        expect(response.parsed_body["success"]).to be(true)
        link = seller.links.last
        expect(link.display_product_reviews).to be(true)
      end

      it "ignores is_in_preorder_state param" do
        params = { price_cents: 100, name: "preorder", is_in_preorder_state: true, release_at: 1.year.from_now.iso8601 }
        post :create, params: { format: :json, link: params }
        expect(response.parsed_body["success"]).to be(true)
        link = seller.links.last
        expect(link.name).to eq "preorder"
        expect(link.price_cents).to eq 100
        expect(link.reload.preorder_link.present?).to be(false)
      end

      it "is able to set currency type" do
        params = { price_cents: 100, name: "test link", url: @s3_url, price_currency_type: "jpy" }
        post :create, params: { format: :json, link: params }
        expect(response.parsed_body["success"]).to be(true)
        expect(Link.last.price_currency_type).to eq "jpy"
      end

      it "creates the product if no files are provided" do
        params = { price_cents: 100, name: "test link", files: {} }
        expect { post :create, params: { format: :json, link: params } }.to change { seller.links.count }.by(1)
      end

      it "assigns 'other' taxonomy" do
        params = { price_cents: 100, name: "test link" }
        post :create, params: { format: :json, link: params }
        expect(response.parsed_body["success"]).to be(true)
        expect(Link.last.taxonomy).to eq(Taxonomy.find_by(slug: "other"))
      end

      context "when the product's native type is bundle" do
        it "sets is_bundle to true" do
          post :create, params: { format: :json, link: { price_cents: 100, name: "Bundle", native_type: "bundle" } }
          expect(response.parsed_body["success"]).to be(true)

          product = Link.last
          expect(product.native_type).to eq("bundle")
          expect(product.is_bundle).to eq(true)
        end
      end

      context "the product is a coffee product" do
        let(:seller) { create(:user, :eligible_for_service_products) }

        it "sets custom_button_text_option to 'donate_prompt'" do
          post :create, params: { format: :json, link: { price_cents: 100, name: "Coffee", native_type: "coffee" } }
          expect(response.parsed_body["success"]).to be(true)

          product = Link.last
          expect(product.native_type).to eq("coffee")
          expect(product.custom_button_text_option).to eq("donate_prompt")
        end
      end

      describe "subscriptions" do
        before do
          @params = { price_cents: 100, name: "test link", is_recurring_billing: true }
        end

        it "defaults should_show_all_posts to true for recurring billing products" do
          post :create, params: { link: @params.merge(subscription_duration: "monthly") }
          expect(Link.last.should_show_all_posts).to eq true

          post :create, params: { link: @params.merge(is_recurring_billing: false) }
          expect(Link.last.should_show_all_posts).to eq false
        end

        describe "monthly duration" do
          before do
            @params.merge!(subscription_duration: "monthly")
            post :create, params: { link: @params }
            @product = Link.last
          end

          it "sets is_recurring_billing correctly" do
            expect(@product.is_recurring_billing).to be(true)
          end

          it "sets the correct duration" do
            expect(@product.subscription_duration).to eq "monthly"
          end
        end

        describe "yearly duration" do
          before do
            @params.merge!(subscription_duration: "yearly")
            post :create, params: { link: @params }
            @product = Link.last
          end

          it "sets is_recurring_billing correctly" do
            expect(@product.is_recurring_billing).to be(true)
          end

          it "sets the correct duration" do
            expect(@product.subscription_duration).to eq "yearly"
          end
        end
      end

      describe "physical" do
        before do
          @params = { price_cents: 100, name: "test physical link", is_physical: true }
        end

        context "when physical products are enabled" do
          before do
            seller.update!(can_create_physical_products: true)
          end

          it "allows users to create physical products" do
            post :create, params: { format: :json, link: @params }
            expect(response.parsed_body["success"]).to be(true)
            product = Link.last
            expect(product.is_physical).to be(true)
            expect(product.skus_enabled).to be(false)
          end
        end

        context "when physical products are disabled" do
          it "returns forbidden" do
            post :create, params: { format: :json, link: @params }
            expect(response).to have_http_status(:forbidden)
          end
        end
      end

      describe "community chat" do
        context "when communities feature is enabled" do
          before do
            Feature.activate_user(:communities, seller)
          end

          it "does not enable community chat by default" do
            params = { price_cents: 100, name: "test link" }

            post :create, params: { format: :json, link: params }

            expect(response.parsed_body["success"]).to be(true)
            product = seller.links.last
            expect(product.community_chat_enabled?).to be(false)
            expect(product.active_community).to be_nil
          end
        end

        context "when communities feature is disabled" do
          before do
            Feature.deactivate_user(:communities, seller)
          end

          it "does not enable community chat" do
            params = { price_cents: 100, name: "test link" }

            post :create, params: { format: :json, link: params }

            expect(response.parsed_body["success"]).to be(true)
            product = seller.links.last
            expect(product.community_chat_enabled?).to be(false)
            expect(product.active_community).to be_nil
          end
        end
      end

      describe "Product details generation using AI" do
        let(:params) do
          {
            name: "UX design mastery using Figma",
            description: "<p>Learn how to design user interfaces using Figma</p>",
            custom_summary: "Learn how to design user interfaces using Figma",
            number_of_content_pages: 2,
            ai_prompt: "Create an ebook on UX design using Figma",
            price_cents: 100,
            native_type: "ebook",
          }
        end

        before do
          Feature.activate_user(:ai_product_generation, seller)
        end

        it "calls AI service when ai_prompt is present and feature is active" do
          service_double = instance_double(Ai::ProductDetailsGeneratorService)
          allow(Ai::ProductDetailsGeneratorService).to receive(:new).and_return(service_double)
          allow(service_double).to receive(:generate_cover_image).and_return({ image_data: "fake_image_data" })
          allow(service_double).to receive(:generate_rich_content_pages).and_return({
                                                                                      pages: [
                                                                                        { "title" => "Introduction", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Welcome to the course" }] }] },
                                                                                        { "title" => "Conclusion", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Thank you for reading this course" }] }] }
                                                                                      ]
                                                                                    })
          allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_return(nil)
          allow_any_instance_of(Link).to receive_message_chain(:asset_previews, :build).and_return(nil)
          allow_any_instance_of(Link).to receive(:build_thumbnail).and_return(nil)

          post :create, params: { format: :json, link: params }

          expect(service_double).to have_received(:generate_cover_image)
          expect(service_double).to have_received(:generate_rich_content_pages)
          expect(response.parsed_body["success"]).to eq(true)

          link = Link.last
          expect(link.name).to eq("UX design mastery using Figma")
          expect(link.description).to eq("<p>Learn how to design user interfaces using Figma</p>")
          expect(link.custom_summary).to eq("Learn how to design user interfaces using Figma")
          expect(link.custom_attributes.sole).to eq({ "name" => "Pages", "value" => "2" })
          expect(link.rich_contents.count).to eq(2)
          expect(link.rich_contents.first.title).to eq("Introduction")
          expect(link.rich_contents.first.description).to eq([{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Welcome to the course" }] }])
          expect(link.rich_contents.last.title).to eq("Conclusion")
          expect(link.rich_contents.last.description).to eq([{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Thank you for reading this course" }] }])
        end

        it "does not call AI service when feature is inactive" do
          Feature.deactivate_user(:ai_product_generation, seller)

          service_double = instance_double(Ai::ProductDetailsGeneratorService)
          allow(Ai::ProductDetailsGeneratorService).to receive(:new).and_return(service_double)
          expect(service_double).not_to receive(:generate_cover_image)
          expect(service_double).not_to receive(:generate_rich_content_pages)

          post :create, params: { format: :json, link: params }
        end

        it "does not call AI service when ai_prompt is blank" do
          service_double = instance_double(Ai::ProductDetailsGeneratorService)
          allow(Ai::ProductDetailsGeneratorService).to receive(:new).and_return(service_double)
          expect(service_double).not_to receive(:generate_cover_image)
          expect(service_double).not_to receive(:generate_rich_content_pages)

          post :create, params: { format: :json, link: { price_cents: 100, name: "Regular Product" } }
        end
      end
    end

    describe "POST release_preorder" do
      before do
        @product = create(:product_with_pdf_file, user: seller, is_in_preorder_state: true)
        create(:rich_content, entity: @product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => @product.product_files.first.external_id, "uid" => SecureRandom.uuid } }])
        @preorder_link = create(:preorder_link, link: @product, release_at: 3.days.from_now)
        @params = { id: @product.unique_permalink }
      end

      it_behaves_like "authorize called for action", :post, :release_preorder do
        let(:record) { @product }
        let(:request_params) { @params }
      end

      it_behaves_like "collaborator can access", :post, :release_preorder do
        let(:product) { @product }
        let(:request_params) { @params }
        let(:response_attributes) { { "success" => true } }
      end

      it "returns the right success value" do
        allow_any_instance_of(PreorderLink).to receive(:release!).and_return(false)
        post :release_preorder, params: @params
        expect(response.parsed_body["success"]).to be(false)

        allow_any_instance_of(PreorderLink).to receive(:release!).and_return(true)
        post :release_preorder, params: @params
        expect(response.parsed_body["success"]).to be(true)
      end

      it "releases the preorder even though the release date is in the future" do
        post :release_preorder, params: @params
        expect(response.parsed_body["success"]).to be(true)
        expect(@preorder_link.reload.released?).to be(true)
      end
    end

    describe "POST send_sample_price_change_email" do
      let(:product) { create(:membership_product, user: seller) }
      let(:tier) { product.default_tier }
      let(:policy_method) { :update? }
      let(:required_params) do
        {
          id: product.unique_permalink,
          tier_id: tier.external_id,
          amount: "7.50",
          recurrence: "yearly",
        }
      end

      it_behaves_like "authorize called for action", :post, :send_sample_price_change_email do
        let(:record) { product }
        let(:request_params) { required_params }
      end

      it "returns an error if the tier ID is incorrect" do
        other_tier = create(:variant)
        post :send_sample_price_change_email, params: required_params.merge(tier_id: other_tier.external_id)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Not found")
      end

      it "raises an error if required params are missing" do
        expect do
          post :send_sample_price_change_email, params: { id: product.unique_permalink, tier_id: tier.external_id }
        end.to raise_error(ActionController::ParameterMissing)
      end

      it "sends a sample price change email to the user" do
        expect do
          post :send_sample_price_change_email, params: required_params.merge(
            custom_message: "<p>hi!</p>",
            effective_date: "2023-04-01",
          )
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :sample_subscription_price_change_notification).with(
          user: user_with_role_for_seller,
          tier:,
          effective_date: Date.parse("2023-04-01"),
          recurrence: "yearly",
          new_price: 7_50,
          custom_message: "<p>hi!</p>",
        )
      end
    end

    it "allows updating and publishing a product without files" do
      product = create(:product, user: seller, purchase_disabled_at: Time.current)

      expect do
        post :update, params: { id: product.unique_permalink, name: "Test" }, format: :json
      end.to change { product.reload.name }.from(product.name).to("Test")

      expect do
        post :publish, params: { id: product.unique_permalink }
      end.to change { product.reload.purchase_disabled_at }.to(nil)
      expect(response.parsed_body["success"]).to eq(true)
      expect(product.alive_product_files.count).to eq(0)
    end
  end

  context "within consumer area" do
    before do
      @user = create(:user)
    end
    let(:product) { create(:product, user: @user) }

    describe "GET show" do
      e404_test(:show)

      before do
        @user = create(:user, :eligible_for_service_products)
        @request.host = URI.parse(@user.subdomain_with_protocol).host
      end

      %w[preview_url description].each do |w|
        it "renders when no #{w}" do
          Rails.cache.clear
          link = create(:product, user: @user, w => nil)
          get :show, params: { id: link.to_param }
          expect(response).to be_successful
        end
      end

      describe "wanted=true parameter" do
        it "passes pay_in_installments parameter to checkout when wanted=true" do
          get :show, params: { id: product.to_param, wanted: "true", pay_in_installments: "true" }

          expect(response).to be_redirect

          redirect_url = URI.parse(response.location)
          expect(redirect_url.path).to eq("/checkout")

          query_params = Rack::Utils.parse_query(redirect_url.query)
          expect(query_params).to include(
            "product" => product.unique_permalink,
            "price" => product.price_cents.to_s,
            "pay_in_installments" => "true",
          )
        end

        it "doesn't redirect to checkout for PWYW products without price" do
          product = create(:product, user: @user, customizable_price: true, price_cents: 1000)

          get :show, params: { id: product.to_param, wanted: "true" }

          expect(response).to be_successful
          expect(response).not_to be_redirect
        end
      end

      context "with user signed in" do
        let(:visitor) { create(:user) }
        let!(:purchase) { create(:purchase, purchaser: visitor, link: product) }

        before do
          sign_in(visitor)
        end

        it "assigns the correct props" do
          get :show, params: { id: product.to_param }

          expect(response).to be_successful
          product_props = assigns(:product_props)
          expect(product_props[:product][:id]).to eq(product.external_id)
          expect(product_props[:purchase][:id]).to eq(purchase.external_id)
        end
      end

      describe "meta tags sanitization" do
        it "properly escapes double quote in content" do
          link = create(:product, user: @user, description: 'I like pie."')
          get :show, params: { id: link.to_param }
          expect(response).to be_successful

          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)

          # nokogiri decodes html entities in tag attributes,
          # so checking for `I like pie."` means you're actually checking for `I like pie.&quot;`
          expect(html_doc.css("meta[name='description'][content='I like pie.\"']")).to_not be_empty
        end

        it "scrubs tags in content" do
          link = create(:product, user: @user, description: "I like pie.&nbsp; <br/>")
          get :show, params: { id: link.to_param }
          expect(response).to be_successful

          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)

          expect(html_doc.css("meta[name='description'][content='I like pie.']")).to_not be_empty
        end

        it "escapes new lines and html tags" do
          link = create(:product, user: @user, description: "I like pie.\n\r This is not <br/> what we had estimated! ~")
          get :show, params: { id: link.to_param }
          expect(response).to be_successful

          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)
          expect(html_doc.css("meta[name='description'][content='I like pie. This is not what we had estimated! ~']")).to_not be_empty
        end
      end

      describe "asset previews" do
        before do
          @product = create(:product_with_file_and_preview, user: @user)
        end

        it "renders the preview container" do
          get(:show, params: { id: @product.to_param })

          expect(response).to be_successful
          expect(response.body).to have_selector("[role=tabpanel][id='#{@product.asset_previews.first.guid}']")
        end

        it "shows preview navigation controls when there is more than one preview" do
          get(:show, params: { id: @product.to_param })
          expect(response.body).to_not have_button("Show next cover")
          expect(response.body).to_not have_tablist("Select a cover")
          create(:asset_preview, link: @product)
          get(:show, params: { id: @product.to_param })
          expect(response.body).to have_tablist("Select a cover")
          expect(response.body).to have_button("Show next cover")
        end
      end

      context "when custom_permalink exists" do
        let(:product) { create(:product, user: @user, custom_permalink: "custom") }

        it "redirects from unique_permalink to custom_permalink URL preserving the original query parameter string" do
          get :show, params: { id: product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

          expect(response).to redirect_to(short_link_url(product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
        end
      end

      describe "redirection to creator's subdomain" do
        before do
          @request.host = DOMAIN
        end

        context "when requested with unique permalink" do
          context "when custom permalink is not present" do
            it "redirects to the subdomain product URL with original query params" do
              product = create(:product)
              get :show, params: { id: product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

              expect(response).to redirect_to(short_link_url(product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
              expect(response).to have_http_status(:moved_permanently)
            end
          end

          context "when custom permalink is present" do
            it "redirects to the subdomain product URL using custom permalink with original query params" do
              product = create(:product, custom_permalink: "abcd")
              get :show, params: { id: product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

              expect(response).to redirect_to(short_link_url(product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
              expect(response).to have_http_status(:moved_permanently)
            end
          end

          context "when offer code is present" do
            it "redirects to subdomain product URL with offer code and original query params" do
              product = create(:product)
              get :show, params: { id: product.unique_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

              expect(response).to redirect_to(short_link_offer_code_url(product.unique_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
              expect(response).to have_http_status(:moved_permanently)
            end
          end
        end

        context "when requested with custom permalink" do
          it "redirects to the subdomain product URL using custom permalink with original query params" do
            product = create(:product, custom_permalink: "abcd")
            get :show, params: { id: product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

            expect(response).to redirect_to(short_link_url(product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
            expect(response).to have_http_status(:moved_permanently)
          end

          context "when offer code is present" do
            it "redirects to subdomain product URL with offer code and original query params" do
              product = create(:product, custom_permalink: "abcd")
              get :show, params: { id: product.custom_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

              expect(response).to redirect_to(short_link_offer_code_url(product.custom_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
              expect(response).to have_http_status(:moved_permanently)
            end
          end
        end
      end

      context "when the product is deleted" do
        let(:product) { create(:product, user: @user, deleted_at: 2.days.ago) }

        it "returns 404" do
          expect do
            get :show, params: { id: product.to_param }
          end.to raise_error(ActionController::RoutingError)
        end
      end

      context "when the product is a coffee product" do
        let!(:product) { create(:product, user: @user, native_type: Link::NATIVE_TYPE_COFFEE) }

        it "redirects to the coffee page" do
          expect(get :show, params: { id: product.to_param }).to redirect_to(custom_domain_coffee_url)
        end
      end

      context "when the user is deleted" do
        let(:user) { create(:user, deleted_at: 2.days.ago) }
        let(:product) { create(:product, custom_permalink: "moohat", user:) }

        it "responds with 404" do
          expect do
            get :show, params: { id: product.to_param }
          end.to raise_error(ActionController::RoutingError)
        end
      end

      it "does not 404 if user is not suspended" do
        link = create(:product, user: @user)
        expect { get :show, params: { id: link.to_param } }.to_not raise_error
      end

      it "404s on an unsupported format" do
        link = create(:product, user: @user)
        expect do
          get(:show, params: { id: link.to_param, format: :php })
        end.to raise_error(ActionController::RoutingError)
      end

      describe "canonical urls" do
        it "renders the canonical meta tag" do
          product = create(:product, user: @user)

          get :show, params: { id: product.unique_permalink }
          expect(response.body).to have_selector("link[rel='canonical'][href='#{product.long_url}']", visible: false)
        end
      end

      describe "product information markup" do
        it "renders schema.org item props for classic product" do
          product = create(:product, user: @user, price_currency_type: "usd", price_cents: 525)
          purchase = create(:purchase, link: product)
          create(:product_review, purchase:)
          create(:asset_preview, link: product, unsplash_url: "https://images.unsplash.com/example.jpeg", attach: false)

          get :show, params: { id: product.unique_permalink }

          expect(response).to be_successful
          expect(response.body).to have_selector("[itemprop='offers'][itemtype='https://schema.org/Offer']")
          expect(response.body).to have_selector("link[itemprop='url'][href='#{product.long_url}']")
          expect(response.body).to have_selector("[itemprop='availability']", text: "https://schema.org/InStock", visible: false)
          expect(response.body).to have_selector("[itemprop='reviewCount']", text: product.reviews_count, visible: false)
          expect(response.body).to have_selector("[itemprop='ratingValue']", text: "1", visible: false)
          expect(response.body).to have_selector("[itemprop='price']", text: product.price_formatted_without_dollar_sign, visible: false)
          expect(response.body).to have_selector("[itemprop='seller'][itemtype='https://schema.org/Person']", visible: false)
          expect(response.body).to have_selector("[itemprop='name']", text: @user.name, visible: false)
          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)
          expect(html_doc.css("meta[content='#{product.long_url}'][property='og:url']")).to be_present
          expect(html_doc.css("meta[property='product:retailer_item_id'][content='#{product.unique_permalink}']")).to be_present
          expect(html_doc.css("meta[property='product:price:amount'][content='5.25']")).to be_present
          expect(html_doc.css("meta[property='product:price:currency'][content='USD']")).to be_present
          expect(html_doc.css("meta[content='#{product.preview_url}'][property='og:image']")).to be_present
        end

        it "renders schema.org item props for product over $1000" do
          product = create(:product, user: @user, price_cents: 1_000_00)
          purchase = create(:purchase, link: product)
          create(:product_review, purchase:)

          get :show, params: { id: product.unique_permalink }

          expect(response).to be_successful
          expect(response.body).to have_selector("[itemprop='offers'][itemtype='https://schema.org/Offer']")
          expect(response.body).to have_selector("link[itemprop='url'][href='#{product.long_url}']")
          expect(response.body).to have_selector("[itemprop='availability']", text: "https://schema.org/InStock", visible: false)
          expect(response.body).to have_selector("[itemprop='reviewCount']", text: product.reviews_count, visible: false)
          expect(response.body).to have_selector("[itemprop='ratingValue']", text: "1", visible: false)
          expect(response.body).to have_selector("[itemprop='price'][content='1000']")
          expect(response.body).to have_selector("[itemprop='priceCurrency']", text: product.price_currency_type, visible: false)
          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)
          expect(html_doc.css("meta[property='product:retailer_item_id'][content='#{product.unique_permalink}']")).to_not be_empty
          expect(html_doc.css("meta[content='#{product.long_url}'][property='og:url']")).to_not be_empty
        end

        it "does not render product review count and rating markup if product has no review" do
          product = create(:product, user: @user)
          get :show, params: { id: product.unique_permalink }
          expect(response.body).to have_selector("link[itemprop='url'][href='#{product.long_url}']")
          expect(response.body).to_not have_selector("div[itemprop='reviewCount']")
          expect(response.body).to_not have_selector("div[itemprop='ratingValue']")
          expect(response.body).to_not have_selector("div[itemprop='aggregateRating']")
          html_doc = Nokogiri::HTML(response.body)
          expect(html_doc.css("meta[content='#{product.long_url}'][property='og:url']")).to_not be_empty
        end

        it "renders schema.org item props for single-tier membership product" do
          recurrence_price_values = {
            BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2.5 },
            BasePrice::Recurrence::BIANNUALLY => { enabled: true, price: 15 },
            BasePrice::Recurrence::YEARLY => { enabled: true, price: 30 },
          }
          product = create(:membership_product, user: @user)
          product.default_tier.save_recurring_prices!(recurrence_price_values)
          get :show, params: { id: product.unique_permalink }
          expect(response).to be_successful
          expect(response.body).to have_selector("div[itemprop='offers'][itemtype='https://schema.org/AggregateOffer']")
          expect(response.body).to have_selector("div[itemprop='offerCount']", text: "1", visible: false)
          expect(response.body).to have_selector("div[itemprop='lowPrice']", text: "2.50", visible: false)
          expect(response.body).to have_selector("div[itemprop='priceCurrency']", text: product.price_currency_type, visible: false)
          expect(response.body).to have_selector("[itemprop='offer'][itemtype='https://schema.org/Offer']", count: 1)
          expect(response.body).to have_selector("div[itemprop='price']", text: "2.50", count: 2, visible: false)
        end

        it "renders schema.org item props for multi-tier membership product" do
          recurrence_price_values = [
            { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2.5 } },
            { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 5 } }
          ]
          product = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:, user: @user)
          get :show, params: { id: product.unique_permalink }
          expect(response).to be_successful
          expect(response.body).to have_selector("div[itemprop='offers'][itemtype='https://schema.org/AggregateOffer']")
          expect(response.body).to have_selector("div[itemprop='offerCount']", text: "2", visible: false)
          expect(response.body).to have_selector("div[itemprop='lowPrice']", text: "2.50", visible: false)
          expect(response.body).to have_selector("div[itemprop='priceCurrency']", text: product.price_currency_type, visible: false)
          expect(response.body).to have_selector("[itemprop='offer'][itemtype='https://schema.org/Offer']", count: 2)
          expect(response.body).to have_selector("div[itemprop='price']", exact_text: "2.50", count: 1, visible: false)
          expect(response.body).to have_selector("div[itemprop='price']", exact_text: "5", count: 1, visible: false)
        end
      end

      it "does not set no index header by default" do
        product = create(:product, user: @user)
        get :show, params: { id: product.unique_permalink }
        expect(response.headers["X-Robots-Tag"]).to be_nil
      end

      context "adult products" do
        it "does not set the noindex header" do
          product = create(:product, user: @user, is_adult: true)

          get :show, params: { id: product.unique_permalink }

          expect(response.headers.keys).not_to include("X-Robots-Tag")
        end
      end

      context "non-alive products" do
        it "sets the noindex header" do
          product = create(:product, user: @user)
          expect_any_instance_of(Link).to receive(:alive?).at_least(:once).and_return(false)

          get :show, params: { id: product.unique_permalink }

          expect(response.headers["X-Robots-Tag"]).to eq("noindex")
        end
      end

      it "sets paypal_merchant_currency as merchant account's currency if native paypal payments are enabled else as usd" do
        product = create(:product, user: @user)

        get :show, params: { id: product.unique_permalink }
        expect(assigns[:paypal_merchant_currency]).to eq "USD"

        create(:merchant_account_paypal, user: product.user, currency: "GBP")
        get :show, params: { id: product.unique_permalink }
        expect(assigns[:paypal_merchant_currency]).to eq "GBP"
      end

      context "when requests come from custom domains" do
        let(:product) { create(:product) }
        let!(:custom_domain) { create(:custom_domain, domain: "www.example1.com", user: nil, product:) }

        before do
          @request.host = "www.example1.com"
        end

        context "when the custom domain matches a product's custom domain" do
          it "assigns the product and renders the show template" do
            get :show
            expect(response).to be_successful
            expect(assigns[:product]).to eq(product)
            expect(response).to render_template(:show)
          end
        end

        context "when the custom domain matches a deleted product" do
          before do
            product.mark_deleted!
          end

          it "raises ActionController::RoutingError" do
            expect { get :show }.to raise_error(ActionController::RoutingError)
          end
        end

        context "when the same domain name is used for a user's deleted custom domain and a product's active custom domain" do
          before do
            custom_domain.update!(product: nil, user: create(:user), deleted_at: DateTime.parse("2020-01-01"))
            create(:custom_domain, domain: "www.example1.com", user: nil, product:)
          end

          it "assigns the product and renders the show template" do
            get :show
            expect(response).to be_successful
            expect(assigns[:product]).to eq(product)
            expect(response).to render_template(:show)
          end
        end

        context "when a product's custom domain is deleted" do
          before do
            custom_domain.mark_deleted!
          end

          it "raises ActionController::RoutingError" do
            expect { get :show }.to raise_error(ActionController::RoutingError)
          end
        end

        context "when a product's saved custom domain does not use the www prefix" do
          before do
            custom_domain.update!(domain: "example1.com")
          end

          it "assigns the product and renders the show template" do
            get :show
            expect(response).to be_successful
            expect(assigns[:product]).to eq(product)
            expect(response).to render_template(:show)
          end
        end
      end

      context "when requests come from subdomains" do
        before do
          @user = create(:user, username: "testuser")
          @request.host = "#{@user.username}.test.gumroad.com"
          stub_const("ROOT_DOMAIN", "test.gumroad.com")
        end

        context "when the subdomain and unique permalink are valid and present" do
          before do
            @product = create(:product, user: @user)
          end

          it "assigns the product and renders the show template" do
            get :show, params: { id: @product.unique_permalink }
            expect(response).to be_successful
            expect(assigns[:product]).to eq(@product)
            expect(response).to render_template(:show)
          end
        end

        context "when the product has custom permalink but accessed through unique permalink" do
          before do
            @product = create(:product, user: @user, custom_permalink: "onetwothree")
          end

          it "redirects unique permalink to custom permalink" do
            get :show, params: { id: @product.unique_permalink }
            expect(response).to redirect_to(@product.long_url)
          end
        end

        context "when the subdomain and custom permalink are valid and present" do
          before do
            @product = create(:product, user: @user, custom_permalink: "test-link")
          end

          it "assigns the product and renders the show template" do
            get :show, params: { id: @product.custom_permalink }
            expect(response).to be_successful
            expect(assigns[:product]).to eq(@product)
            expect(response).to render_template(:show)
          end
        end

        context "when the seller from subdomain is different from product's seller" do
          before do
            @product = create(:product, user: create(:user, username: "anotheruser"))
          end

          it "raises ActionController::RoutingError" do
            expect { get :show, params: { id: @product.unique_permalink } }.to raise_error(ActionController::RoutingError)
          end
        end
      end

      context "when request comes from a legacy product URL" do
        before do
          @product_1 = create(:product, unique_permalink: "abc", custom_permalink: "custom")
          @product_2 = create(:product, unique_permalink: "xyz", custom_permalink: "custom")
          @request.host = DOMAIN
        end

        context "when looked up by unique permalink" do
          it "redirects to a product URL with subdomain and custom permalink" do
            get :show, params: { id: "abc" }

            expect(response).to redirect_to(@product_1.long_url)
          end
        end

        context "when looked up by custom permalink" do
          it "redirects to a full product URL of the oldest product matched by custom permalink" do
            get :show, params: { id: "custom" }

            expect(response).to redirect_to(@product_1.long_url)
          end
        end
      end

      describe "legacy products lookup" do
        before do
          @user = create(:user)

          # product by another user, created earlier in time
          @other_product = create(:product, user: create(:user), custom_permalink: "custom")

          # product by another user with legacy permalink mapping
          @product_with_legacy_mapping = create(:product, user: create(:user), custom_permalink: "custom")
          create(:legacy_permalink, permalink: "custom", product: @product_with_legacy_mapping)

          # the user's product, created later in time
          @product = create(:product, user: @user, custom_permalink: "custom")
        end

        context "when request comes from a legacy URL" do
          before do
            @request.host = DOMAIN
          end

          it "redirects to a product defined by legacy permalink" do
            get :show, params: { id: "custom" }

            expect(response).to redirect_to(@product_with_legacy_mapping.long_url)
          end

          context "when legacy permalink points to a deleted product" do
            before do
              @product_with_legacy_mapping.mark_deleted!
            end

            it "redirects to an earlier product matched by permalink" do
              get :show, params: { id: "custom" }

              expect(response).to redirect_to(@other_product.long_url)
            end
          end
        end

        context "when request comes from a custom domain" do
          before do
            @domain = CustomDomain.create(domain: "www.example1.com", user: @user)
            @request.host = "www.example1.com"
          end

          it "renders the user's product" do
            get :show, params: { id: "custom" }

            expect(response).to be_successful
            expect(assigns[:product]).to eq(@product)
          end
        end

        context "when request comes from a subdomain URL" do
          before do
            @request.host = "#{@user.username}.test.gumroad.com"
            stub_const("ROOT_DOMAIN", "test.gumroad.com")
          end

          it "renders the user's product" do
            get :show, params: { id: "custom" }

            expect(response).to be_successful
            expect(assigns[:product]).to eq(@product)
          end
        end
      end

      describe "setting affiliate cookie" do
        let(:product) { create(:product) }
        let(:direct_affiliate) { create(:direct_affiliate, seller: product.user, products: [product]) }
        let(:host) { URI.parse(product.user.subdomain_with_protocol).host }

        Affiliate::QUERY_PARAMS.each do |query_param|
          context "with `#{query_param}` query param" do
            it_behaves_like "AffiliateCookie concern" do
              subject(:make_request) do
                @request.host = host
                get :show, params: { id: product.unique_permalink, query_param => direct_affiliate.external_id_numeric }
              end
            end
          end
        end
      end

      it "adds X-Robots-Tag response header to avoid page indexing only if the url contains an offer code" do
        product = create(:product, unique_permalink: "abc", user: @user)

        get :show, params: { id: product.unique_permalink, code: "10off" }
        expect(response.headers["X-Robots-Tag"]).to eq("noindex")

        get :show, params: { id: product.unique_permalink }
        expect(response.headers.keys).not_to include("X-Robots-Tag")

        get :show, params: { id: product.unique_permalink, code: "20off" }
        expect(response.headers["X-Robots-Tag"]).to eq("noindex")
      end

      describe "Discover tracking" do
        it "stores click when coming from discover" do
          cookies[:_gumroad_guid] = "custom_guid"

          expect do
            get :show, params: { id: product.to_param, recommended_by: "search", query: "something", autocomplete: "true" }
          end.to change(DiscoverSearch, :count).by(1)

          expect(DiscoverSearch.last!.attributes).to include(
            "query" => "something",
            "ip_address" => "0.0.0.0",
            "browser_guid" => "custom_guid",
            "autocomplete" => true,
            "clicked_resource_type" => product.class.name,
            "clicked_resource_id" => product.id,
          )

          expect do
            get :show, params: { id: product.to_param, recommended_by: "discover", query: "something" }
          end.to change(DiscoverSearch, :count).by(1)


          expect(DiscoverSearch.last!.attributes).to include(
            "query" => "something",
            "ip_address" => "0.0.0.0",
            "browser_guid" => "custom_guid",
            "autocomplete" => false,
            "clicked_resource_type" => product.class.name,
            "clicked_resource_id" => product.id,
          )
        end

        it "does not store click when not coming from discover" do
          expect do
            get :show, params: { id: product.to_param }
          end.not_to change(DiscoverSearch, :count)
        end
      end
    end

    describe "GET cart_items_count" do
      it "assigns the correct instance variables and excludes third-party analytics scripts" do
        get :cart_items_count

        expect(assigns(:hide_layouts)).to eq(true)
        expect(assigns(:disable_third_party_analytics)).to eq(true)

        html = Nokogiri::HTML.parse(response.body)
        [
          "gr:google_analytics:enabled",
          "gr:fb_pixel:enabled",
        ].each do |property|
          expect(html.xpath("//meta[@property='#{property}']/@content").text).to eq("false")
        end
      end
    end

    describe "POST increment_views" do
      before do
        @product = create(:product)
        @request.env["HTTP_USER_AGENT"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.165 Safari/535.19"
        ElasticsearchIndexerWorker.jobs.clear
      end

      shared_examples "records page view" do
        it "does record page view" do
          post :increment_views, params: { id: @product.to_param }
          expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", hash_including("class_name" => "ProductPageView"))
        end
      end

      context "with a logged out visitor" do
        before do
          sign_out @user
        end

        include_examples "records page view"
      end

      context "with a logged out user" do
        include_examples "records page view"
      end

      context "when requests come from custom domains" do
        before do
          @request.host = "www.example1.com"
          create(:custom_domain, domain: "www.example1.com", user: nil, product: create(:product))
        end

        include_examples "records page view"
      end

      describe "data recorded", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        let(:last_page_view_data) do
          ProductPageView.search({ sort: { timestamp: :desc }, size: 1 }).first["_source"]
        end

        before do
          recreate_model_index(ProductPageView)
          travel_to Time.utc(2021, 1, 1)
          sign_in @user
        end

        it "sets basic data" do
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data).to equal_with_indifferent_access(
            product_id: @product.id,
            seller_id: @product.user_id,
            country: nil,
            state: nil,
            referrer_domain: "direct",
            timestamp: "2021-01-01T00:00:00Z",
            user_id: @user.id,
            ip_address: "0.0.0.0",
            url: "/links/#{@product.unique_permalink}/increment_views",
            browser_guid: cookies[:_gumroad_guid],
            browser_fingerprint: Digest::MD5.hexdigest(@request.env["HTTP_USER_AGENT"] + ","),
            referrer: nil,
          )
        end

        it "sets country and state from custom IP address" do
          @request.remote_ip = "54.234.242.13"
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data.with_indifferent_access).to include(
            country: "United States",
            state: "VA",
            ip_address: "54.234.242.13",
          )
        end

        it "sets referrer" do
          @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data.with_indifferent_access).to include(
            referrer_domain: "youtube.com",
            referrer: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          )
        end

        it "sets referrer via HTTP header" do
          @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data.with_indifferent_access).to include(
            referrer_domain: "youtube.com",
            referrer: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          )
        end

        it "sets referrer via params" do
          post :increment_views, params: {
            id: @product.to_param,
            referrer: "https://gum.co/posts/news-新しい?#{"1" * 200}&extra",
          }
          expect(last_page_view_data.with_indifferent_access).to include(
            referrer_domain: "gum.co",
            referrer: "https://gum.co/posts/news-?#{"1" * 164}", # limited to first 190 chars
          )
        end

        it "sets custom browser_guid" do
          cookies[:_gumroad_guid] = "custom_guid"
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data[:browser_guid]).to eq("custom_guid")
        end

        it "sets user_id to nil when the user is signed out" do
          sign_out @user
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data[:user_id]).to eq(nil)
        end

        it "sets correct referrer_domain when product is not recommended" do
          @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          post :increment_views, params: {
            id: @product.to_param,
            was_product_recommended: false
          }
          expect(last_page_view_data[:referrer_domain]).to eq("youtube.com")
        end

        it "sets correct referrer_domain when product is recommended" do
          @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          post :increment_views, params: {
            id: @product.to_param,
            was_product_recommended: true
          }
          expect(last_page_view_data[:referrer_domain]).to eq("recommended_by_gumroad")
        end
      end

      it "does not record page view for the seller of the product" do
        allow(controller).to receive(:current_user).and_return(@product.user)
        post :increment_views, params: { id: @product.to_param }

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end

      it "does not record page view for an admin user" do
        allow(controller).to receive(:current_user).and_return(create(:admin_user))
        post :increment_views, params: { id: @product.to_param }

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end

      context "with user signed in as admin for seller" do
        include_context "with user signed in as admin for seller" do
          let(:seller) { @product.user }
        end

        it "does not record page view" do
          post :increment_views, params: { id: @product.to_param }

          expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
        end
      end

      it "does not record page view for bots" do
        @request.env["HTTP_USER_AGENT"] = "EventMachine HttpClient"
        post :increment_views, params: { id: @product.to_param }

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end

      it "does not record page view for an admin becoming user" do
        sign_in create(:admin_user)
        controller.impersonate_user(@user)
        post :increment_views, params: { id: @product.to_param }

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end
    end

    describe "POST track_user_action" do
      context "with signed in user" do
        before do
          sign_in @user
        end

        shared_examples "creates an event" do
          it "writes the event to the events table" do
            post :track_user_action, params: { id: product.to_param, event_name: "link_view" }
            event = Event.last!
            expect(event.event_name).to eq "link_view"
            expect(event.link_id).to eq product.id
          end
        end

        context "with a product" do
          let(:product) { create(:product) }

          include_examples "creates an event"

          context "when requests come from custom domains" do
            before do
              @request.host = "www.example1.com"
              create(:custom_domain, domain: "www.example1.com", user: nil, product:)
            end

            include_examples "creates an event"
          end
        end
      end
    end

    describe "create_purchase_event" do
      it "creates a purchase event" do
        cookies[:_gumroad_guid] = "blahblahblah"
        @product = create(:product)
        purchase = create(:purchase, link: @product)
        controller.create_purchase_event(purchase)
        expect(Event.order(:id).last.event_name).to eq "purchase"
      end
    end

    describe "GET search" do
      before do
        @recommended_by = "search"
        @on_profile = false
      end

      def product_json(product, target, query = request.params["query"])
        ProductPresenter.card_for_web(product:, request: @request, recommended_by: @recommended_by, show_seller: !@on_profile, target:, query:).as_json
      end

      describe "Setting and ordering" do
        before do
          Link.__elasticsearch__.create_index!(force: true)
          @creator = create(:compliant_user, username: "creatordudey", name: "Creator Dudey")
          @section = create(:seller_profile_products_section, seller: @creator)
          @product = create(:product, name: "Top quality weasel", user: @creator, taxonomy: Taxonomy.find_or_create_by(slug: "3d"))
          create(:purchase, :with_review, link: @product, created_at: 1.week.ago)
          create(:product_review, link: @product)
          Link.import(force: true, refresh: true)
        end

        it "returns the expected JSON response when no search parameters are specified" do
          res = {
            "total" => 1,
            "filetypes_data" => [],
            "tags_data" => [],
            "products" => [product_json(@product, "discover")]
          }
          get :search
          expect(response.parsed_body).to eq(res)

          get :search, params: { query: "" }
          expect(response.parsed_body).to eq(res)
        end

        it "returns the expected JSON response when searching by a user" do
          @product.tag!("mustelid")
          @on_profile = true
          @recommended_by = nil
          another_product = create(:product, name: "Another product", user: @creator)
          products = create_list(:product, 20, user: @creator)
          product3 = create(:product, user: @creator)
          create(:product_file, link: another_product)
          create(:product, name: "Bad product", user: @creator)
          shown_products = [@product, product3, another_product] + products
          @section.update!(shown_products: shown_products.map { _1.id })
          Link.import(force: true, refresh: true)

          get :search, params: { user_id: @creator.external_id, section_id: @section.external_id }

          expect(response.parsed_body).to eq({
                                               "total" => 23,
                                               "filetypes_data" => [{ "doc_count" => 1, "key" => "pdf" }],
                                               "tags_data" => [{ "doc_count" => 1, "key" => "mustelid" }],
                                               "products" => shown_products[0...9].map { product_json(_1, "profile") }
                                             })
        end


        it "returns products in page layout order when applicable if searching by user" do
          @recommended_by = nil
          @on_profile = true
          product_b = create(:product, name: "First product", user: @creator)
          product_c = create(:product, name: "Second product", user: @creator)
          create(:product, name: "Hide me", user: @creator)
          @section.update!(shown_products: [product_b, product_c, @product].map { _1.id })
          Link.import(force: true, refresh: true)

          get :search, params: { user_id: @creator.external_id, section_id: @section.external_id }
          expect(response.parsed_body["products"]).to eq([product_json(product_b, "profile"), product_json(product_c, "profile"), product_json(@product, "profile")])
        end

        it "returns an empty response when searching by non-existent user" do
          get :search, params: { user_id: 1640736000000, section_id: @section.id }
          expect(response.parsed_body).to eq({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "products" => [] })
        end

        it "returns an empty response when searching by non-existent section" do
          get :search, params: { user_id: @creator.external_id, section_id: 1640736000000 }
          expect(response.parsed_body).to eq({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "products" => [] })

          section = create(:seller_profile_posts_section, seller: @creator)
          get :search, params: { user_id: @creator.external_id, section_id: section.id }
          expect(response.parsed_body).to eq({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "products" => [] })
        end

        it "searches only for recommendable products" do
          bad_text = "Previously-owned weasel"
          bad = create(:product, name: bad_text)
          @product.tag!("mustelid")
          bad.tag!("irrelevant")
          create(:product_file, link: @product)
          create(:product_review, purchase: create(:purchase, link: @product, created_at: 1.month.ago))
          Link.import(force: true, refresh: true)

          get :search, params: { query: "weasel" }

          expect(response.parsed_body).to eq({
                                               "total" => 1,
                                               "filetypes_data" => [{ "doc_count" => 1, "key" => "pdf" }],
                                               "tags_data" => [{ "doc_count" => 1, "key" => "mustelid" }],
                                               "products" => [product_json(@product, "discover")]
                                             })
        end

        it "returns product in fee revenue order" do
          products = %i[meh unpopular popular old].each_with_object({}) do |name, h|
            h[name] = create(:product)
            h[name].tag!("ocelot")
            expect(h[name]).to receive(:recommendable?).at_least(:once).and_return(true)
          end
          travel_to(4.months.ago) { 4.times { create(:purchase, link: products[:old]) } }
          3.times { create(:purchase, link: products[:popular]) }
          2.times { create(:purchase, link: products[:meh]) }
          create(:purchase, link: products[:unpopular])
          index_model_records(Purchase)
          products.each do |_key, product|
            allow(product).to receive(:reviews_count).and_return(1)
            product.__elasticsearch__.index_document
            allow(product).to receive(:reviews_count).and_call_original
          end
          Link.__elasticsearch__.refresh_index!
          get :search, params: { query: "ocelot" }

          expect(response.parsed_body["products"]).to eq([
                                                           product_json(products[:popular], "discover"),
                                                           product_json(products[:meh], "discover"),
                                                           product_json(products[:unpopular], "discover"),
                                                           product_json(products[:old], "discover")
                                                         ])
        end

        it "searches successfully for a product with a regex character" do
          @product.update(name: "Top [quality weasel")
          Link.import(force: true, refresh: true)
          get :search, params: { query: "Top [quality" }
          expect(response.parsed_body["products"]).to eq([product_json(@product, "discover")])
        end
      end

      describe "Loose and exact matching" do
        before do
          @products = {
            name: create(:product, name: "North American river otter"),
            desc: create(:product, description: "The North American river otter, also known as the northern river otter or the common otter, is a semiaquatic mammal."),
            creator: create(:product, user: create(:user, name: "Brig. Gen. W. North American River Otter III")),
            inexact: create(:product, description: "An American otter is found in the north river."),
            partial: create(:product, name: "Just an ordinary otter"),
            cross_field: create(:product, name: "River otter", description: "Animals of this description are common and live in the North and the South of the American and European continents."),
            tagged: create(:product, name: "River otter")
          }
          @products[:tagged].tag!("North American")
          @products[:tagged].tag!("common")
          @products.each do |_key, product|
            expect(product).to receive(:recommendable?).at_least(:once).and_return(true)
            allow(product).to receive(:reviews_count).and_return(1)
            product.__elasticsearch__.index_document
            allow(product).to receive(:reviews_count).and_call_original
          end
          Link.__elasticsearch__.refresh_index!
        end

        it "finds all matches if exact match not specified" do
          get :search, params: { query: "north american river otter" }
          expect(response.parsed_body["products"]).to match_array(%i[name desc creator inexact cross_field tagged].map { |key| product_json(@products[key], "discover") })
        end

        it "finds exact match if double-quotes used" do
          get :search, params: { query: '" north american river otter  "' }
          expect(response.parsed_body["products"]).to match_array(%i[name desc creator].map { |key| product_json(@products[key], "discover") })
        end

        it "finds compound match when double-quotes used in combination with another term" do
          get :search, params: { query: 'common "river otter"' }
          expect(response.parsed_body["products"]).to match_array(%i[desc cross_field tagged].map { |key| product_json(@products[key], "discover") })
        end

        it "finds results for a complex match across different fields" do
          get :search, params: { query: 'north "river otter" american' }
          expect(response.parsed_body["products"]).to match_array(%i[name desc creator cross_field tagged].map { |key| product_json(@products[key], "discover") })
        end

        it "handles potentially malformed query" do
          get :search, params: { query: "\\" }
          expect(response.parsed_body["products"]).to eq([])
        end
      end

      describe "Filtering" do
        describe "for products with no reviews" do
          before do
            @user = create(:recommendable_user)
            @section = create(:seller_profile_products_section, seller: @user)
            @product_without_review = create(:product, name: "sample 2", user: @user)
            @product_with_review = create(:product, :recommendable, name: "sample 1", user: @user)
            create(:product_review, purchase: create(:purchase, link: @product_with_review))

            Link.__elasticsearch__.refresh_index!
          end

          it "filters on discover" do
            get :search, params: { query: "sample" }
            expect(response.parsed_body["products"]).to eq([product_json(@product_with_review, "discover")])
          end

          it "does not filter on profile" do
            @recommended_by = nil
            @on_profile = true
            get :search, params: { user_id: @user.external_id, section_id: @section.external_id }
            expect(response.parsed_body["products"]).to eq([product_json(@product_without_review, "profile"), product_json(@product_with_review, "profile")])
          end
        end
      end

      describe "Discover tracking" do
        it "stores the search query along with useful metadata" do
          cookies[:_gumroad_guid] = "custom_guid"
          sign_in @user

          expect do
            get :search, params: { query: "something", taxonomy: "3d" }
          end.to change(DiscoverSearch, :count).by(1)

          expect(DiscoverSearch.last!.attributes).to include(
            "query" => "something",
            "user_id" => @user.id,
            "taxonomy_id" => Taxonomy.find_by_path(["3d"]).id,
            "ip_address" => "0.0.0.0",
            "browser_guid" => "custom_guid",
            "autocomplete" => false
          )
        end

        it "does not store search when querying user products" do
          expect do
            get :search, params: { query: "something", user_id: @user.id }
          end.not_to change(DiscoverSearch, :count)
        end
      end
    end
  end
end
