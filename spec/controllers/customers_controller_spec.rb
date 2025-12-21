# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe CustomersController, :vcr, type: :controller, inertia: true do
  render_views

  let(:seller) { create(:named_user) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    let(:product1) { create(:product, user: seller, name: "Product 1", price_cents: 100) }
    let(:product2) { create(:product, user: seller, name: "Product 2", price_cents: 200) }
    let!(:purchase1) { create(:purchase, link: product1, full_name: "Customer 1", email: "customer1@gumroad.com", created_at: 1.day.ago, seller:) }
    let!(:purchase2) { create(:purchase, link: product2, full_name: "Customer 2", email: "customer2@gumroad.com", created_at: 2.days.ago, seller:) }

    before do
      Feature.activate_user(:react_customers_page, seller)
      index_model_records(Purchase)
    end

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Purchase }
      let(:policy_klass) { Audience::PurchasePolicy }
      let(:policy_method) { :index? }
    end

    it "returns HTTP success and renders the correct inertia component and props" do
      get :index
      expect(response).to be_successful
      expect(inertia).to render_component("Customers/Index")
      expect(inertia.props[:customers_presenter][:pagination]).to eq(next: nil, page: 1, pages: 1)
      expect(inertia.props[:customers_presenter][:customers]).to match_array([hash_including(id: purchase1.external_id), hash_including(id: purchase2.external_id)])
      expect(inertia.props[:customers_presenter][:count]).to eq(2)
      expect(inertia.props).not_to have_key(:customer_emails)
      expect(inertia.props).not_to have_key(:missed_posts)
      expect(inertia.props).not_to have_key(:workflows)
    end

    context "for a specific product" do
      it "renders the correct inertia component and props" do
        get :index, params: { link_id: product1.unique_permalink }
        expect(response).to be_successful
        expect(inertia).to render_component("Customers/Index")
        expect(inertia.props[:customers_presenter][:customers]).to match_array([hash_including(id: purchase1.external_id)])
        expect(inertia.props[:customers_presenter][:product_id]).to eq(product1.external_id)
      end
    end

    context "for partial visits" do
      let(:product) { create(:product, user: seller) }
      let(:purchase) { create(:purchase, link: product, created_at: Time.current - 15.seconds) }

      before do
        request.headers["X-Inertia-Partial-Component"] = "Customers/Index"
      end

      it "when customer is selected it loads customer_emails, missed_posts, and workflows together" do
        create(:installment, link: product, seller: seller, published_at: 1.day.ago)
        workflow = create(:workflow, link: product, seller: seller, published_at: 1.day.ago)
        create(:workflow_installment, workflow: workflow, seller: seller, published_at: 1.day.ago, link_id: workflow.link_id)
        request.headers["X-Inertia-Partial-Data"] = "customer_emails,missed_posts,workflows"
        get :index, params: { purchase_id: purchase.external_id }

        expect(response).to be_successful
        expect(inertia.props).not_to have_key(:customers_presenter)

        expect(inertia.props[:customer_emails]).to be_an(Array)
        expect(inertia.props[:customer_emails]).not_to be_empty
        expect(inertia.props[:customer_emails].first).to have_key(:type)
        expect(inertia.props[:customer_emails].first).to have_key(:id)
        expect(inertia.props[:customer_emails].first).to have_key(:url)

        expect(inertia.props[:missed_posts]).to be_an(Array)
        expect(inertia.props[:missed_posts]).not_to be_empty
        expect(inertia.props[:missed_posts].first).to have_key(:id)
        expect(inertia.props[:missed_posts].first).to have_key(:name)
        expect(inertia.props[:missed_posts].first).to have_key(:url)
        expect(inertia.props[:missed_posts].first).to have_key(:published_at)

        expect(inertia.props[:workflows]).to be_an(Array)
        expect(inertia.props[:workflows]).not_to be_empty
        expect(inertia.props[:workflows].first).to have_key(:id)
        expect(inertia.props[:workflows].first).to have_key(:label)
      end

      it "when workflow is changed it loads only missed_posts" do
        request.headers["X-Inertia-Partial-Data"] = "missed_posts"
        get :index, params: { purchase_id: purchase.external_id }

        expect(response).to be_successful
        expect(inertia.props).not_to have_key(:customer_emails)
        expect(inertia.props).not_to have_key(:customers_presenter)
        expect(inertia.props).to have_key(:missed_posts)
        expect(inertia.props[:missed_posts]).to be_an(Array)

        expect(inertia.props).not_to have_key(:workflows)
      end

      context "product_purchases" do
        let(:bundle_purchase) { create(:purchase, link: create(:product, :bundle, user: seller), seller:) }

        before { bundle_purchase.create_artifacts_and_send_receipt! }

        it "includes product_purchases in props for bundle purchases" do
          request.headers["X-Inertia-Partial-Data"] = "product_purchases"
          get :index, params: { purchase_id: bundle_purchase.external_id }

          expect(response).to be_successful
          expect(inertia.props[:product_purchases]).to be_an(Array)
          expect(inertia.props[:product_purchases]).to eq(bundle_purchase.product_purchases.map { CustomerPresenter.new(purchase: _1).customer(pundit_user: SellerContext.new(user: seller, seller:)) })
        end

        it "does not include product_purchases when purchase is not a bundle" do
          regular_purchase = create(:purchase, link: create(:product, user: seller), seller: seller)
          request.headers["X-Inertia-Partial-Data"] = "product_purchases"
          get :index, params: { purchase_id: regular_purchase.external_id }

          expect(response).to be_successful
          expect(inertia.props).not_to have_key(:product_purchases)
        end
      end

      it "returns 404 if no purchase" do
        expect do
          request.headers["X-Inertia-Partial-Data"] = "customer_emails,missed_posts,workflows"
          get :index, params: { purchase_id: "hello" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "GET paged" do
    let(:product) { create(:product, user: seller, name: "Product 1", price_cents: 100) }
    let!(:purchases) do
      create_list :purchase, 6, seller:, link: product do |purchase, i|
        purchase.update!(full_name: "Customer #{i}", email: "customer#{i}@gumroad.com", created_at: ActiveSupport::TimeZone[seller.timezone].parse("January #{i + 1} 2023"), license: create(:license, link: product, purchase:))
      end
    end

    before do
      index_model_records(Purchase)
      stub_const("CustomersController::CUSTOMERS_PER_PAGE", 3)
    end

    it "returns HTTP success and assigns the correct instance variables" do
      customer_ids = -> (res) { res.parsed_body.deep_symbolize_keys[:customers].map { _1[:id] } }

      get :paged, params: { page: 2, sort: { key: "created_at", direction: "asc" } }
      expect(response).to be_successful
      expect(customer_ids[response]).to eq(purchases[3..].map(&:external_id))

      get :paged, params: { page: 1, query: "customer0" }
      expect(response).to be_successful
      expect(customer_ids[response]).to eq([purchases.first.external_id])

      get :paged, params: { page: 1, query: purchases.first.license.serial }
      expect(response).to be_successful
      expect(customer_ids[response]).to eq([purchases.first.external_id])

      get :paged, params: { page: 1, created_after: ActiveSupport::TimeZone[seller.timezone].parse("January 3 2023"), created_before: ActiveSupport::TimeZone[seller.timezone].parse("January 4 2023") }
      expect(response).to be_successful
      expect(customer_ids[response]).to match_array([purchases.third.external_id, purchases.fourth.external_id])
    end
  end

  describe "GET charges" do
    before do
      @product = create(:product, user: seller)
      @subscription = create(:subscription, link: @product, user: create(:user))
      @original_purchase = create(:purchase, link: @product, price_cents: 100,
                                             is_original_subscription_purchase: true, subscription: @subscription, created_at: 1.day.ago)
      @purchase1 = create(:purchase, link: @product, price_cents: 100,
                                     is_original_subscription_purchase: false, subscription: @subscription, created_at: 1.day.from_now)
      @purchase2 = create(:purchase, link: @product, price_cents: 100,
                                     is_original_subscription_purchase: false, subscription: @subscription, created_at: 2.days.from_now)
      @upgrade_purchase = create(:purchase, link: @product, price_cents: 200,
                                            is_original_subscription_purchase: false, subscription: @subscription, created_at: 3.days.from_now, is_upgrade_purchase: true)
      @new_original_purchase = create(:purchase, link: @product, price_cents: 300,
                                                 is_original_subscription_purchase: true, subscription: @subscription, created_at: 3.days.ago, purchase_state: "not_charged")
    end

    it_behaves_like "authorize called for action", :get, :customer_charges do
      let(:record) { Purchase }
      let(:policy_klass) { Audience::PurchasePolicy }
      let(:policy_method) { :index? }
      let(:request_params) { { purchase_id: @original_purchase.external_id } }
    end

    let!(:chargedback_purchase) do
      create(:purchase, link: @product, price_cents: 100, chargeback_date: DateTime.current,
                        is_original_subscription_purchase: false, subscription: @subscription, created_at: 1.day.from_now)
    end

    before { Feature.activate_user(:react_customers_page, seller) }

    context "when purchase is an original subscription purchase" do
      it "returns all recurring purchases" do
        get :customer_charges, params: { purchase_id: @original_purchase.external_id, purchase_email: @original_purchase.email }
        expect(response).to be_successful
        expect(response.parsed_body.map { _1["id"] }).to match_array([@original_purchase.external_id, @purchase1.external_id, @purchase2.external_id, @upgrade_purchase.external_id, chargedback_purchase.external_id])
      end
    end

    context "when purchase is a commission deposit purchase", :vcr do
      let!(:commission) { create(:commission) }

      before { commission.create_completion_purchase! }

      it "returns the deposit and completion purchases" do
        get :customer_charges, params: { purchase_id: commission.deposit_purchase.external_id, purchase_email: commission.deposit_purchase.email }
        expect(response).to be_successful
        expect(response.parsed_body.map { _1["id"] }).to eq([commission.deposit_purchase.external_id, commission.completion_purchase.external_id])
      end
    end

    context "when the purchase isn't found" do
      it "returns 404" do
        expect do
          get :customer_charges, params: { purchase_id: "fake" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
