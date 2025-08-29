# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::AffiliatesController do
  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller) }
  let(:affiliate_user) { create(:affiliate_user) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authentication required for action", :get, :index

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { DirectAffiliate }
    end

    it "fetches affiliates sorted by most recently updated by default" do
      stub_const("AffiliatesPresenter::PER_PAGE", 1)

      products = [create(:product, user: seller), create(:product, user: seller)]
      create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "user1"), products: products.take(2))
      affiliate_user_2 = create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "user2"), products: products.take(1))
      ProductAffiliate.first.update!(affiliate_basis_points: 500, updated_at: 4.days.ago)
      ProductAffiliate.second.update!(affiliate_basis_points: 1000, updated_at: 8.days.ago)
      ProductAffiliate.third.update!(affiliate_basis_points: 1500, updated_at: 2.days.ago)

      get :index, format: :json
      expect(response).to be_successful
      expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)
    end

    it "only fetches affiliate requests when specified" do
      create(:affiliate_request, seller:)

      get :index, params: { should_get_affiliate_requests: true }, format: :json
      expect(response).to be_successful
      expect(response.parsed_body["affiliate_requests"]).not_to be_empty

      get :index, params: { should_get_affiliate_requests: false }, format: :json
      expect(response).to be_successful
      expect(response.parsed_body["affiliate_requests"]).to be_empty
    end

    context "when paginating" do
      it "assigns the correct affiliates" do
        stub_const("AffiliatesPresenter::PER_PAGE", 1)
        affiliate_user_1 = create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "user1"), products: [create(:product, user: seller)])
        affiliate_user_2 = create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "user2"), products: [create(:product, user: seller)])
        affiliate_request = create(:affiliate_request, seller:)
        ProductAffiliate.find_by(affiliate_id: affiliate_user_1.id).update!(updated_at: Time.now + 1)
        ProductAffiliate.find_by(affiliate_id: affiliate_user_2.id).update!(updated_at: Time.now - 1)

        get :index, params: { should_get_affiliate_requests: true }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body.deep_symbolize_keys).to match(
          affiliate_requests: [affiliate_request.as_json(pundit_user: controller.pundit_user)],
          affiliates: [seller.direct_affiliates.first.as_json],
          pagination: { page: 1, pages: 2 },
          allow_approve_all_requests: false,
          affiliates_disabled_reason: nil
        )

        get :index, params: { page: 2 }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body.deep_symbolize_keys).to match(
          affiliate_requests: [],
          affiliates: [seller.direct_affiliates.last.as_json],
          pagination: { page: 2, pages: 2 },
          allow_approve_all_requests: false,
          affiliates_disabled_reason: nil
        )
      end

      it "raises an exception when the specified 'page' option is an overflowing page number" do
        expect do
          get :index, params: { page: 2 }, format: :json
        end.to raise_error(Pagy::OverflowError)
      end
    end

    context "when sorting" do
      it "returns the correct order of affiliates" do
        stub_const("AffiliatesPresenter::PER_PAGE", 1)

        products = [create(:product, user: seller), create(:product, user: seller)]
        affiliate_user_1 = create(:direct_affiliate, seller:, affiliate_user: create(:user, username: "aff1", email: "aff1@example.com", name: "aff1"), products: products.take(1))
        affiliate_user_2 = create(:direct_affiliate, seller:, affiliate_user: create(:user, username: "aff2", email: "aff2@example.com", name: "aff2"), products: products.take(2))
        ProductAffiliate.first.update_columns(affiliate_basis_points: 500)
        ProductAffiliate.second.update_columns(affiliate_basis_points: 1000)
        ProductAffiliate.third.update_columns(affiliate_basis_points: 1000)
        create(:purchase_with_balance, link: products.first, affiliate_credit_cents: 100, affiliate: affiliate_user_2)

        get :index, params: { page: 1, sort: { key: "affiliate_user_name", direction: "asc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_1.external_id)

        get :index, params: { page: 1, sort: { key: "affiliate_user_name", direction: "desc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)

        get :index, params: { page: 2, sort: { key: "affiliate_user_name", direction: "asc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)

        get :index, params: { page: 1, sort: { key: "products", direction: "asc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_1.external_id)

        get :index, params: { page: 1, sort: { key: "products", direction: "desc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)

        get :index, params: { page: 2, sort: { key: "products", direction: "asc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)

        get :index, params: { page: 1, sort: { key: "fee_percent", direction: "asc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_1.external_id)

        get :index, params: { page: 1, sort: { key: "fee_percent", direction: "desc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)

        get :index, params: { page: 2, sort: { key: "fee_percent", direction: "asc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)

        get :index, params: { page: 1, sort: { key: "volume_cents", direction: "asc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_1.external_id)

        get :index, params: { page: 1, sort: { key: "volume_cents", direction: "desc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)

        get :index, params: { page: 2, sort: { key: "volume_cents", direction: "asc" } }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].first).to include("id" => affiliate_user_2.external_id)
      end
    end

    context "when searching" do
      let!(:affiliates) do
        affiliates = []
        2.times do |i|
          name = "aff#{i}foobar"
          affiliate_user = create(:user, username: name, email: "#{name}@example.com", name:)
          affiliates << create(:direct_affiliate, seller:, affiliate_user:)
        end
        affiliates
      end
      let!(:affiliate) do
        affiliate = affiliates.last
        affiliate.affiliate_user.update_columns(
          username: "george",
          email: "john@example.com",
          name: "Thomas"
        )
        affiliate
      end

      it "returns affiliates matching query" do
        get :index, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"].size).to eq(2)

        ["geor", "joh", " john@example.com ", "thom"].each do |query_string|
          get :index, params: { query: query_string }, format: :json

          expect(response).to be_successful
          expect(response.parsed_body["affiliates"].size).to eq(1)
          expect(response.parsed_body["affiliates"].first).to include("id" => affiliate.external_id)
        end

        get :index, params: { query: "non-existent" }, format: :json
        expect(response).to be_successful
        expect(response.parsed_body["affiliates"]).to be_empty
      end

      context "when searching" do
        let!(:affiliates) do
          affiliates = []
          2.times do |i|
            name = "aff#{i}foobar"
            affiliate_user = create(:user, username: name, email: "#{name}@example.com", name:)
            affiliates << create(:direct_affiliate, seller:, affiliate_user:)
          end
          affiliates
        end
        let!(:affiliate) do
          affiliate = affiliates.last
          affiliate.affiliate_user.update_columns(
            username: "george",
            email: "john@example.com",
            name: "Thomas"
          )
          affiliate
        end

        it "returns affiliates matching query" do
          ["geor", "joh", " john@example.com ", "thom"].each do |query_string|
            get :index, params: { page: 1, query: query_string }
            expect(response).to be_successful
            expect(response.parsed_body[:affiliates].size).to eq(1)
            expect(response.parsed_body[:affiliates].first).to include(id: affiliate.external_id)
          end

          get :index, params: { page: 1, query: "non-existent" }
          expect(response).to be_successful
          expect(response.parsed_body[:affiliates]).to be_empty
        end
      end
    end
  end

  describe "GET statistics" do
    let(:products) { [create(:product, user: seller, price_cents: 10_00), create(:product, user: seller, price_cents: 20_00)] }
    let!(:affiliate) { create(:direct_affiliate, seller:, affiliate_user: create(:user, name: "user1"), products:) }

    before do
      ProductAffiliate.first.update_columns(affiliate_basis_points: 500)
      ProductAffiliate.second.update_columns(affiliate_basis_points: 1000)

      create(:purchase_with_balance, link: products.first, affiliate_credit_cents: 100, affiliate:)
      create_list(:purchase_with_balance, 2, link: products.second, affiliate_credit_cents: 100,  affiliate:)
    end

    it_behaves_like "authorize called for action", :get, :statistics do
      let(:policy_klass) { DirectAffiliatePolicy }
      let(:request_params) { { id: affiliate.external_id } }
      let(:record) { affiliate }
    end

    it "returns the affiliate's statistics" do
      get :statistics, params: { id: affiliate.external_id }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body["total_volume_cents"]).to eq(50_00)
      expect(response.parsed_body["products"]).to eq(
        products[0].external_id_numeric.to_s => { "sales_count" => 1, "volume_cents" => 10_00 },
        products[1].external_id_numeric.to_s => { "sales_count" => 2, "volume_cents" => 40_00 }
      )
    end
  end

  describe "GET show" do
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1500, products: [product]) }

    it_behaves_like "authentication required for action", :get, :show do
      let(:request_params) { { id: direct_affiliate.external_id } }
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { direct_affiliate }
      let(:request_params) { { id: direct_affiliate.external_id } }
    end

    it "successfully returns the affiliate when found" do
      get :show, params: { id: direct_affiliate.external_id }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body).to eq(
        {
          "id" => direct_affiliate.external_id,
          "email" => direct_affiliate.affiliate_user.email,
          "affiliate_user_name" => direct_affiliate.affiliate_user.display_name(prefer_email_over_default_username: true),
          "fee_percent" => 15,
          "destination_url" => nil,
          "products" => [
            {
              "id" => product.external_id_numeric,
              "name" => product.name,
              "enabled" => true,
              "fee_percent" => 15,
              "volume_cents" => 0,
              "sales_count" => 0,
              "referral_url" => direct_affiliate.referral_url_for_product(product),
              "destination_url" => nil,
            }
          ]
        }
      )
    end

    it "raises an e404 if the affiliate is not found" do
      get :show, params: { id: "non-existent-id" }, format: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ "success" => false, "error" => "Not found" })
    end
  end

  describe "GET onboarding" do
    it_behaves_like "authentication required for action", :get, :onboarding

    it_behaves_like "authorize called for action", :get, :onboarding do
      let(:record) { DirectAffiliate }
      let(:policy_method) { :index? }
    end

    it "returns the correct response" do
      stub_const("AffiliatesPresenter::PER_PAGE", 1)
      create(:product, name: "My product", user: seller, purchase_disabled_at: DateTime.current)
      product_one = create(:product, name: "First product", user: seller)
      product_two = create(:product, name: "Learn Ruby", user: seller)
      product_four = create(:product, name: "Microeconomics 101", user: seller)
      create(:self_service_affiliate_product, seller:, product: product_two, enabled: false)
      create(:self_service_affiliate_product, seller:, product: product_four, enabled: true)

      get :onboarding, format: :json
      expect(response).to be_successful
      expect(response.parsed_body).to eq(
      {
        "creator_subdomain" => seller.subdomain,
        "products" => [
          { "name" => "Microeconomics 101", "enabled" => true, "id" => product_four.external_id_numeric, "fee_percent" => 5, "destination_url" => nil },
          { "name" => "First product", "enabled" => false, "id" => product_one.external_id_numeric, "fee_percent" => nil, "destination_url" => nil },
          { "name" => "Learn Ruby", "enabled" => false, "id" => product_two.external_id_numeric, "fee_percent" => 5, "destination_url" => nil },
          { "name" => product.name, "enabled" => false, "id" => product.external_id_numeric, "fee_percent" => nil, "destination_url" => nil },
        ],
        "disable_global_affiliate" => false,
        "global_affiliate_percentage" => 10,
        "affiliates_disabled_reason" => nil
      })
    end
  end

  describe "POST create", :vcr do
    let(:params) do
      {
        affiliate: {
          email: affiliate_user.email,
          products: [{ id: product.external_id_numeric, enabled: true, fee_percent: 10 }],
          apply_to_all_products: false,
          fee_percent: nil,
          destination_url: ""
        },
      }
    end

    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { params }
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { DirectAffiliate }
      let(:request_params) { params }
    end

    it "successfully creates an affiliate" do
      post :create, params:, as: :json
      expect(response.parsed_body["success"]).to eq(true)

      direct_affiliate = DirectAffiliate.last
      expect(direct_affiliate.seller).to eq(seller)
      expect(direct_affiliate.affiliate_user).to eq(affiliate_user)
      expect(direct_affiliate.products).to eq([product])
      expect(direct_affiliate.apply_to_all_products).to be false
      expect(direct_affiliate.send_posts).to be true
    end

    it "doesn't allow an affiliate to be created if the affiliate user email is invalid" do
      post :create, params: params.deep_merge(affiliate: { email: "some@bad.email" }), as: :json
      expect(response.parsed_body["success"]).to eq(false)
      expect(DirectAffiliate.count).to eq(0)
    end

    it "does not allow affiliate to be created if the email belongs to a deleted user" do
      deleted_user = create(:affiliate_user, :deleted)

      expect do
        post :create, params: params.deep_merge(affiliate: { email: deleted_user.email }), as: :json
      end.to_not change { DirectAffiliate.count }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to eq("The affiliate has not created a Gumroad account with this email address.")
    end

    it "does not allow affiliate to be created if the fee_percent is missing and applies to all products" do
      expect do
        post :create, params: params.deep_merge(affiliate: { fee_percent: nil, apply_to_all_products: true }), as: :json
      end.to_not change { DirectAffiliate.count }
      expect(response.parsed_body["success"]).to eq(false)
    end

    it "does not allow affiliate to be created if a product fee is missing and applies to specific products" do
      expect do
        post :create, params: params.deep_merge(affiliate: { apply_to_all_products: false, products: [{ id: product.external_id_numeric, enabled: true, fee_percent: nil }] }), as: :json
      end.to_not change { DirectAffiliate.count }
      expect(response.parsed_body["success"]).to eq(false)
    end

    it "does not allow affiliate to be created if seller is using a Brazilian Stripe Connect account" do
      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: seller, country: "BR")
      seller.update!(check_merchant_account_is_linked: true)
      expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      expect do
        post :create, params:, as: :json
      end.to_not change { DirectAffiliate.count }
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("You cannot add an affiliate because you are using a Brazilian Stripe account.")
    end

    it "does not allow affiliate to be created if affiliate user is using a Brazilian Stripe Connect account" do
      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: affiliate_user, country: "BR")
      affiliate_user.update!(check_merchant_account_is_linked: true)
      expect(affiliate_user.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      expect do
        post :create, params:, as: :json
      end.to_not change { DirectAffiliate.count }
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("This user cannot be added as an affiliate because they use a Brazilian Stripe account.")
    end

    it "does not allow affiliate to be created if affiliate user has disabled being added as an affiliate" do
      affiliate_user.update!(disable_affiliate_requests: true)

      expect do
        post :create, params:, as: :json
      end.to_not change { DirectAffiliate.count }
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("This user has disabled being added as an affiliate.")
    end

    context "with affiliate user being the seller" do
      before { sign_in(seller) }

      it "doesn't allow an affiliate to be created if the affiliate user is the same as the creator" do
        post :create, params: params.deep_merge(affiliate: { email: seller.email }), as: :json

        expect(response.parsed_body["success"]).to eq(false)
        expect(DirectAffiliate.count).to eq(0)
      end
    end

    context "with apply_to_all_products enabled" do
      before do
        create(:product, user: seller, deleted_at: Time.current)
        create(:product, user: seller, archived: true)
      end

      it "affiliates the user with all live products" do
        post :create, params: params.deep_merge(affiliate: { apply_to_all_products: true, fee_percent: 10 }), as: :json

        direct_affiliate = seller.direct_affiliates.last
        expect(direct_affiliate.products).to eq [product]
        expect(direct_affiliate.apply_to_all_products).to be true
      end

      context "when an archived product has self service affiliate enabled" do
        let!(:archived_product_enabled) { create(:product, user: seller, archived: true) }

        before do
          create(:self_service_affiliate_product, seller:, product: archived_product_enabled, enabled: true)
        end

        it "includes the archived product in the affiliate products" do
          post :create, params: params.deep_merge(affiliate: { apply_to_all_products: true, fee_percent: 10 }), as: :json

          direct_affiliate = seller.direct_affiliates.last
          expect(direct_affiliate.products).to eq [product, archived_product_enabled]
          expect(direct_affiliate.apply_to_all_products).to be true
        end
      end
    end

    context "with seller merchant migration enabled" do
      before do
        Feature.activate_user(:merchant_migration, seller)
      end

      after do
        Feature.deactivate_user(:merchant_migration, seller)
      end

      it "allows an affiliate to be created if the affiliate user does not have any merchant account" do
        post :create, params:, as: :json
        expect(response.parsed_body["success"]).to eq(true)
      end

      it "allows affiliate to be created if the affiliate user has all merchant accounts connected" do
        create(:merchant_account_stripe, user: affiliate_user)
        create(:merchant_account_paypal, user: affiliate_user)
        post :create, params:, as: :json
        expect(response.parsed_body["success"]).to eq(true)
      end

      it "allows affiliate to be created if the affiliate user has only Paypal merchant account" do
        create(:merchant_account_stripe, user: affiliate_user)
        post :create, params:, as: :json
        expect(response.parsed_body["success"]).to eq(true)
      end

      it "allows affiliate to be created if the affiliate user has only Stripe merchant account" do
        create(:merchant_account_stripe, user: affiliate_user)
        post :create, params:, as: :json
        expect(response.parsed_body["success"]).to eq(true)
      end
    end

    it "returns JSON error if email is missing" do
      post :create, params: { affiliate: params[:affiliate].except(:email) }, as: :json
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq(nil)
    end

    context "when seller has multiple products" do
      let!(:product_2) { create(:product, user: seller) }

      it "enables only the selected products" do
        extra_params = {
          affiliate: {
            products: [
              { id: product.external_id_numeric, enabled: true, fee_percent: 10, destination_url: "https://example.com" },
              { id: product_2.external_id_numeric, enabled: false, fee_percent: nil }
            ]
          }
        }

        post :create, params: params.deep_merge(extra_params), as: :json
        expect(response.parsed_body["success"]).to eq(true)

        direct_affiliate = DirectAffiliate.last
        expect(direct_affiliate.product_affiliates.size).to eq(1)
        product_affiliate = direct_affiliate.product_affiliates.first
        expect(product_affiliate.link_id).to eq(product.id)
        expect(product_affiliate.affiliate_basis_points).to eq(1000)
        expect(product_affiliate.destination_url).to eq("https://example.com")
      end

      it "allows setting different fees and URLs for different products" do
        extra_params = {
          affiliate: {
            products: [
              { id: product.external_id_numeric, enabled: true, fee_percent: 10, destination_url: "https://example.com" },
              { id: product_2.external_id_numeric, enabled: true, fee_percent: 20, destination_url: "https://example2.com" }
            ]
          }
        }

        post :create, params: params.deep_merge(extra_params), as: :json

        expect(response.parsed_body["success"]).to eq(true)

        direct_affiliate = DirectAffiliate.last
        expect(direct_affiliate.product_affiliates.size).to eq(2)
        product_affiliate = direct_affiliate.product_affiliates.first
        expect(product_affiliate.link_id).to eq(product.id)
        expect(product_affiliate.affiliate_basis_points).to eq(1000)
        expect(product_affiliate.destination_url).to eq("https://example.com")
        product_affiliate_2 = direct_affiliate.product_affiliates.last
        expect(product_affiliate_2.link_id).to eq(product_2.id)
        expect(product_affiliate_2.affiliate_basis_points).to eq(2000)
        expect(product_affiliate_2.destination_url).to eq("https://example2.com")
      end

      it "does not create a new affiliate if one product is missing the fee_percent" do
        expect do
          post :create, params: params.deep_merge(affiliate: { products: [{ id: product.external_id_numeric, enabled: true, fee_percent: 10 }, { id: product_2.external_id_numeric, enabled: true, fee_percent: nil }] }), as: :json
        end.to_not change { DirectAffiliate.count }

        expect(response.parsed_body["success"]).to eq(false)
      end
    end

    it "does not allow creating a new affiliate if another one already exists" do
      affiliate_2 = create(:direct_affiliate, seller:, affiliate_user:)
      create(:product_affiliate, affiliate: affiliate_2, product:)

      expect do
        post :create, params:, as: :json
      end.to_not change { DirectAffiliate.count }

      expect(response.parsed_body).to eq({ "success" => false, "message" => "This affiliate already exists." })
    end

    context "when another seller has an affiliate with the same email" do
      let(:another_seller) { create(:user) }
      let(:another_product) { create(:product, user: another_seller) }
      let(:params) do
        {
          affiliate: {
            email: affiliate_user.email,
            products: [{ id: another_product.external_id_numeric, enabled: true, fee_percent: 10 }],
            apply_to_all_products: false,
            fee_percent: nil,
            destination_url: ""
          },
        }
      end

      before { sign_in(another_seller) }

      it "creates the affiliate successfully" do
        expect do
          post :create, params:, as: :json
        end.to change { DirectAffiliate.count }.by(1)

        expect(response.parsed_body["success"]).to eq(true)
      end
    end
  end

  describe "PATCH update" do
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller:) }
    let!(:product_affiliate) { create(:product_affiliate, affiliate: direct_affiliate, product:) }
    let(:params) do
      {
        id: direct_affiliate.external_id,
        affiliate: {
          email: affiliate_user.email,
          products: [{ id: product.external_id_numeric, enabled: true, fee_percent: 10 }],
          apply_to_all_products: false,
          fee_percent: nil,
          destination_url: ""
        },
      }
    end

    it_behaves_like "authentication required for action", :put, :update do
      let(:request_params) { params }
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { direct_affiliate }
      let(:request_params) { params }
    end

    it "raises an e404 if the affiliate is not found" do
      patch :update, params: params.merge(id: "non-existent-id"), format: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ "success" => false, "error" => "Not found" })
    end

    context "when affiliate should be an affiliate for all seller's products" do
      it "creates affiliate products for all live products" do
        other_products = create_list(:product, 2, user: seller)
        affiliated_products = other_products.push(product)
        extra_params = {
          affiliate:
            {
              fee_percent: 10,
              apply_to_all_products: true,
              products: affiliated_products.map do |product| { id: product.external_id_numeric, enabled: true, fee_percent: 10 }
              end
            }
        }
        create(:product, user: seller).mark_deleted!

        patch :update, params: params.deep_merge(extra_params), as: :json
        expect(response.parsed_body["success"]).to eq(true)

        direct_affiliate.reload
        expect(direct_affiliate.apply_to_all_products).to eq(true)
        expect(direct_affiliate.affiliate_basis_points).to eq(1000)
        expect(direct_affiliate.product_affiliates.size).to eq(3)
        expect(direct_affiliate.product_affiliates.map(&:link_id)).to match_array(affiliated_products.map(&:id))
        expect(direct_affiliate.product_affiliates.map(&:affiliate_basis_points).uniq).to contain_exactly(1000)
      end
    end

    it "notifies the affiliate of the changes when enabling a new product" do
      new_product = create(:product, user: seller)
      extra_params = {
        affiliate: {
          products: [
            { id: new_product.external_id_numeric, enabled: true, fee_percent: 10 },
            { id: product.external_id_numeric, enabled: true, fee_percent: 10 }
          ]
        }
      }
      expect do
        patch :update, params: params.deep_merge(extra_params), as: :json
      end.to have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_updated_products).with(direct_affiliate.id)
    end

    it "notifies the affiliate of changes when updating the fee of an existing product" do
      extra_params = {
        affiliate: {
          products: [
            { id: product.external_id_numeric, enabled: true, fee_percent: 5 },
          ]
        }
      }

      expect do
        post :update, params: params.deep_merge(extra_params), as: :json
      end.to have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_updated_products).with(direct_affiliate.id)
    end

    it "does not notify the affiliate of changes when the destination URLs were changed" do
      allow(AffiliateMailer).to receive(:notify_direct_affiliate_of_updated_products)

      extra_params = {
        affiliate: {
          destination_url: "https://example.com",
          products: [
            { id: product.external_id_numeric, enabled: true, fee_percent: 10, destination_url: "https://example2.com" },
          ]
        }
      }

      patch :update, params: params.deep_merge(extra_params), as: :json

      expect(AffiliateMailer).not_to have_received(:notify_direct_affiliate_of_updated_products)
    end

    it "does not notify the affiliate of changes when products were untouched" do
      allow(AffiliateMailer).to receive(:notify_direct_affiliate_of_updated_products)

      patch :update, params: params.deep_merge(affiliate: { destination_url: "https://example.com" }), as: :json

      expect(AffiliateMailer).not_to have_received(:notify_direct_affiliate_of_updated_products)
    end

    it "does not allow removing the only enabled product from affiliate" do
      extra_params = {
        affiliate: {
          products: [
            { id: product.external_id_numeric, enabled: false, fee_percent: 10 },
          ]
        }
      }

      expect do
        patch :update, params: params.deep_merge(extra_params), as: :json
      end.to_not change { direct_affiliate.reload.product_affiliates.size }

      expect(response.parsed_body["success"]).to eq(false)
    end

    it "removes the product from the affiliate if it is disabled" do
      new_product = create(:product, user: seller)
      extra_params = {
        affiliate: {
          products: [
            { id: new_product.external_id_numeric, enabled: true, fee_percent: 5 },
            { id: product.external_id_numeric, enabled: false, fee_percent: 10 }
          ]
        }
      }

      patch :update, params: params.deep_merge(extra_params), as: :json
      expect(response.parsed_body["success"]).to eq(true)
      expect(direct_affiliate.reload.product_affiliates.size).to eq(1)
      product_affiliate = direct_affiliate.product_affiliates.first
      expect(product_affiliate.link_id).to eq(new_product.id)
      expect(product_affiliate.affiliate_basis_points).to eq(500)
    end

    it "updates the product with the new settings" do
      extra_params = {
        affiliate: {
          products: [{ id: product.external_id_numeric, enabled: true, fee_percent: 20, destination_url: "https://example.com" }],
        }
      }

      patch :update, params: params.deep_merge(extra_params), as: :json
      expect(response.parsed_body["success"]).to eq(true)
      expect(direct_affiliate.reload.product_affiliates.size).to eq(1)
      product_affiliate = direct_affiliate.product_affiliates.first
      expect(product_affiliate.link_id).to eq(product.id)
      expect(product_affiliate.affiliate_basis_points).to eq(20_00)
      expect(product_affiliate.destination_url).to eq("https://example.com")
    end

    it "updates the product's destination URL when 'apply_to_all_products' is enabled" do
      extra_params = {
        affiliate: {
          fee_percent: 20,
          apply_to_all_products: true,
          products: [{ id: product.external_id_numeric, enabled: true, fee_percent: 20, destination_url: "https://example.com" }],
        }
      }

      expect do
        patch :update, params: params.deep_merge(extra_params), as: :json
      end.to change { direct_affiliate.product_affiliates.first.reload.destination_url }.from(nil).to("https://example.com")
    end
  end

  describe "DELETE destroy" do
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1500, products: [product]) }

    it_behaves_like "authentication required for action", :delete, :destroy do
      let(:request_params) { { id: direct_affiliate.external_id } }
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { direct_affiliate }
      let(:request_params) { { id: direct_affiliate.external_id } }
    end

    it "successfully marks the affiliate as deleted" do
      delete :destroy, params: { id: direct_affiliate.external_id }, format: :json

      expect(response.parsed_body["success"]).to eq(true)
      expect(DirectAffiliate.last.deleted_at).to be_present
    end

    it "successfully sends notification email to affiliate" do
      expect do
        delete :destroy, params: { id: direct_affiliate.external_id }, format: :json
      end.to have_enqueued_mail(AffiliateMailer, :direct_affiliate_removal).with(direct_affiliate.id)
    end

    it "raises an e404 if the affiliate is not found" do
      delete :destroy, params: { id: "non-existent-id" }, format: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ "success" => false, "error" => "Not found" })
    end
  end
end
