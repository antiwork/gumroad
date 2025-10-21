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

  describe "GET customer_emails" do
    it_behaves_like "authorize called for action", :get, :customer_emails do
      let(:record) { Purchase }
      let(:policy_klass) { Audience::PurchasePolicy }
      let(:policy_method) { :index? }
      let(:request_params) { { purchase_id: "hello" } }
    end

    context "with classic product" do
      before do
        @product = create(:product, user: seller)
        now = Time.current
        @purchase = create(:purchase, link: @product, created_at: now - 15.seconds)
        @post1 = create(:installment, link: @product, published_at: now - 10.seconds)
        @post2 = create(:installment, link: @product, published_at: now - 5.seconds)
        @post3 = create(:installment, link: @product, published_at: nil)
      end

      it "returns 404 if no purchase" do
        expect do
          get :customer_emails, params: { purchase_id: "hello" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns success true with only receipt default values" do
        get :customer_emails, params: { purchase_id: @purchase.external_id }
        expect(response).to be_successful
        expect(response.parsed_body.size).to eq 1
        expect(response.parsed_body[0]["type"]).to eq("receipt")
        expect(response.parsed_body[0]["id"]).to be_present
        expect(response.parsed_body[0]["name"]).to eq "Receipt"
        expect(response.parsed_body[0]["state"]).to eq "Delivered"
        expect(response.parsed_body[0]["state_at"]).to be_present
        expect(response.parsed_body[0]["url"]).to eq receipt_purchase_url(@purchase.external_id, email: @purchase.email)
      end

      it "returns success true with only receipt" do
        create(:customer_email_info_opened, purchase: @purchase)
        get :customer_emails, params: { purchase_id: @purchase.external_id }
        expect(response).to be_successful
        expect(response.parsed_body.size).to eq 1
        expect(response.parsed_body[0]["type"]).to eq("receipt")
        expect(response.parsed_body[0]["id"]).to eq(@purchase.external_id)
        expect(response.parsed_body[0]["name"]).to eq "Receipt"
        expect(response.parsed_body[0]["state"]).to eq "Opened"
        expect(response.parsed_body[0]["state_at"]).to be_present
        expect(response.parsed_body[0]["url"]).to eq receipt_purchase_url(@purchase.external_id, email: @purchase.email)
      end

      it "returns success true with receipt and posts" do
        create(:customer_email_info_opened, purchase: @purchase)
        create(:creator_contacting_customers_email_info_delivered, installment: @post1, purchase: @purchase)
        create(:creator_contacting_customers_email_info_opened, installment: @post2, purchase: @purchase)
        create(:creator_contacting_customers_email_info_delivered, installment: @post3, purchase: @purchase)
        post_from_diff_user = create(:installment, link: @product, seller: create(:user), published_at: Time.current)
        create(:creator_contacting_customers_email_info_delivered, installment: post_from_diff_user, purchase: @purchase)
        get :customer_emails, params: { purchase_id: @purchase.external_id }
        expect(response).to be_successful
        expect(response.parsed_body.count).to eq 4

        expect(response.parsed_body[0]["type"]).to eq("receipt")
        expect(response.parsed_body[0]["id"]).to eq @purchase.external_id
        expect(response.parsed_body[0]["state"]).to eq "Opened"
        expect(response.parsed_body[0]["url"]).to eq receipt_purchase_url(@purchase.external_id, email: @purchase.email)

        expect(response.parsed_body[1]["type"]).to eq("post")
        expect(response.parsed_body[1]["id"]).to eq @post2.external_id
        expect(response.parsed_body[1]["state"]).to eq "Opened"

        expect(response.parsed_body[2]["type"]).to eq("post")
        expect(response.parsed_body[2]["id"]).to eq @post1.external_id
        expect(response.parsed_body[2]["state"]).to eq "Delivered"

        expect(response.parsed_body[3]["type"]).to eq("post")
        expect(response.parsed_body[3]["id"]).to eq @post3.external_id
        expect(response.parsed_body[3]["state"]).to eq "Delivered"
      end
    end

    context "with subscription product" do
      it "returns all receipts and posts ordered by date" do
        product = create(:membership_product, subscription_duration: "monthly", user: seller)
        buyer = create(:user, credit_card: create(:credit_card))
        subscription = create(:subscription, link: product, user: buyer)

        travel_to 1.month.ago

        original_purchase = create(:purchase_with_balance,
                                   link: product,
                                   seller: product.user,
                                   subscription:,
                                   purchaser: buyer,
                                   is_original_subscription_purchase: true)
        create(:customer_email_info_opened, purchase: original_purchase)

        travel_back

        first_post = create(:published_installment, link: product, name: "Thanks for buying!")

        travel 1

        recurring_purchase = create(:purchase_with_balance,
                                    link: product,
                                    seller: product.user,
                                    subscription:,
                                    purchaser: buyer)

        travel 1

        second_post = create(:published_installment, link: product, name: "Will you review my course?")
        create(:creator_contacting_customers_email_info_opened, installment: second_post, purchase: original_purchase)

        travel 1

        # Second receipt email opened after the posts were published, should still be ordered by time of purchase
        create(:customer_email_info_opened, purchase: recurring_purchase)
        # First post delivered after second one; should still be ordered by publish time
        create(:creator_contacting_customers_email_info_delivered, installment: first_post, purchase: original_purchase)

        # A post sent to customers of the same product, but with filters that didn't match this purchase
        unrelated_post = create(:published_installment, link: product, name: "Message to other folks!")
        create(:creator_contacting_customers_email_info_delivered, installment: unrelated_post)

        get :customer_emails, params: { purchase_id: original_purchase.external_id }

        expect(response).to be_successful

        expect(response.parsed_body.count).to eq 4

        expect(response.parsed_body[0]["type"]).to eq("receipt")
        expect(response.parsed_body[0]["id"]).to eq original_purchase.external_id
        expect(response.parsed_body[0]["name"]).to eq "Receipt"
        expect(response.parsed_body[0]["state"]).to eq "Opened"
        expect(response.parsed_body[0]["url"]).to eq receipt_purchase_url(original_purchase.external_id, email: original_purchase.email)


        expect(response.parsed_body[1]["type"]).to eq("receipt")
        expect(response.parsed_body[1]["id"]).to eq recurring_purchase.external_id
        expect(response.parsed_body[1]["name"]).to eq "Receipt"
        expect(response.parsed_body[1]["state"]).to eq "Opened"
        expect(response.parsed_body[1]["url"]).to eq receipt_purchase_url(recurring_purchase.external_id, email: recurring_purchase.email)

        expect(response.parsed_body[2]["type"]).to eq("post")
        expect(response.parsed_body[2]["id"]).to eq second_post.external_id
        expect(response.parsed_body[2]["state"]).to eq "Opened"

        expect(response.parsed_body[3]["type"]).to eq("post")
        expect(response.parsed_body[3]["id"]).to eq first_post.external_id
        expect(response.parsed_body[3]["state"]).to eq "Delivered"
      end

      it "includes receipts for free trial original purchases" do
        product = create(:membership_product, :with_free_trial_enabled)
        original_purchase = create(:membership_purchase, link: product, is_free_trial_purchase: true, purchase_state: "not_charged")
        create(:customer_email_info_opened, purchase: original_purchase)

        sign_in product.user
        get :customer_emails, params: { purchase_id: original_purchase.external_id }

        expect(response).to be_successful

        expect(response.parsed_body.count).to eq 1

        email_info  = response.parsed_body[0]
        expect(email_info["type"]).to eq("receipt")
        expect(email_info["id"]).to eq original_purchase.external_id
        expect(email_info["name"]).to eq "Receipt"
        expect(email_info["state"]).to eq "Opened"
        expect(email_info["url"]).to eq receipt_purchase_url(original_purchase.external_id, email: original_purchase.email)
      end
    end

    context "when the purchase uses a charge receipt" do
      let(:product) { create(:product, user: seller) }
      let(:purchase) { create(:purchase, link: product) }
      let(:charge) { create(:charge, purchases: [purchase], seller:) }
      let(:order) { charge.order }
      let!(:email_info) do
        create(
          :customer_email_info,
          purchase_id: nil,
          state: :opened,
          opened_at: Time.current,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
          email_info_charge_attributes: { charge_id: charge.id }
        )
      end

      before do
        order.purchases << purchase
      end

      it "returns EmailInfo from charge" do
        get :customer_emails, params: { purchase_id: purchase.external_id }
        expect(response).to be_successful

        expect(response.parsed_body.count).to eq 1
        email_info  = response.parsed_body[0]
        expect(email_info["type"]).to eq("receipt")
        expect(email_info["id"]).to eq purchase.external_id
        expect(email_info["name"]).to eq "Receipt"
        expect(email_info["state"]).to eq "Opened"
        expect(email_info["url"]).to eq receipt_purchase_url(purchase.external_id, email: purchase.email)
      end
    end
  end

  describe "GET missed_posts" do
    before do
      @product = create(:product, user: seller)
      @post1 = create(:installment, link: @product, published_at: Time.current)
      @post2 = create(:installment, link: @product, published_at: Time.current)
      @post3 = create(:installment, link: @product, published_at: Time.current)
      @unpublished_post = create(:installment, link: @product)
      @purchase = create(:purchase, link: @product)
      create(:creator_contacting_customers_email_info_delivered, installment: @post1, purchase: @purchase)
    end

    it_behaves_like "authorize called for action", :get, :missed_posts do
      let(:record) { Purchase }
      let(:policy_klass) { Audience::PurchasePolicy }
      let(:policy_method) { :index? }
      let(:request_params) { { purchase_id: @purchase.external_id } }
    end

    it "returns success true with missed updates" do
      get :missed_posts, params: { purchase_id: @purchase.external_id, purchase_email: @purchase.email }
      expect(response).to be_successful
      expect(response.parsed_body.count).to eq(2)
      expect(response.parsed_body[0]["name"]).to eq(@post2.name)
      expect(response.parsed_body[0]["published_at"].to_date).to eq(@post2.published_at.to_date)
      expect(response.parsed_body[0]["url"]).to eq(custom_domain_view_post_url(host: seller.subdomain_with_protocol, slug: @post2.slug))
      expect(response.parsed_body[1]["name"]).to eq(@post3.name)
      expect(response.parsed_body[1]["published_at"].to_date).to eq(@post3.published_at.to_date)
      expect(response.parsed_body[1]["url"]).to eq(custom_domain_view_post_url(host: seller.subdomain_with_protocol, slug: @post3.slug))
      expect(response.parsed_body[2]).to eq(nil)
    end

    context "when the purchase is a bundle product purchase" do
      it "excludes receipts" do
        purchase = create(:purchase, is_bundle_product_purchase: true)
        get :missed_posts, params: { purchase_id: purchase.external_id, purchase_email: purchase.email }
        expect(response).to be_successful
        expect(response.parsed_body).to eq([])
      end
    end

    it "returns 404 if no purchase" do
      expect do
        get :missed_posts, params: { purchase_id: "hello" }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "GET product_purchases" do
    let(:purchase) { create(:purchase, link: create(:product, :bundle, user: seller), seller:) }

    before { purchase.create_artifacts_and_send_receipt! }

    it_behaves_like "authorize called for action", :get, :missed_posts do
      let(:record) { Purchase }
      let(:policy_klass) { Audience::PurchasePolicy }
      let(:policy_method) { :index? }
      let(:request_params) { { purchase_id: purchase.external_id } }
    end

    it "returns product purchases" do
      get :product_purchases, params: { purchase_id: purchase.external_id }
      expect(response.parsed_body.map(&:deep_symbolize_keys)).to eq(
        purchase.product_purchases.map { CustomerPresenter.new(purchase: _1).customer(pundit_user: SellerContext.new(user: seller, seller:)) }
      )
    end

    context "no product purchases" do
      it "returns an empty array" do
        get :product_purchases, params: { purchase_id: create(:purchase, seller:, link: create(:product, user: seller)).external_id }
        expect(response.parsed_body).to eq([])
      end
    end
  end
end
