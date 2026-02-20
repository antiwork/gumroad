# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/customer_drawer_missed_posts_context"
require "inertia_rails/rspec"

describe CustomersController, :vcr, type: :controller, inertia: true do
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

      context "customer_emails" do
        before do
          request.headers["X-Inertia-Partial-Data"] = "customer_emails"
        end
        context "with classic product" do
          it "returns success true with only receipt default values" do
            get :index, params: { purchase_id: purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 1
            expect(inertia.props[:customer_emails][0][:type]).to eq("receipt")
            expect(inertia.props[:customer_emails][0][:id]).to be_present
            expect(inertia.props[:customer_emails][0][:name]).to eq "Receipt"
            expect(inertia.props[:customer_emails][0][:state]).to eq "Delivered"
            expect(inertia.props[:customer_emails][0][:state_at]).to be_present
            expect(inertia.props[:customer_emails][0][:url]).to eq receipt_purchase_url(purchase.external_id, email: purchase.email)
          end

          it "returns success true with only receipt" do
            create(:customer_email_info_opened, purchase: purchase)
            get :index, params: { purchase_id: purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 1
            expect(inertia.props[:customer_emails][0][:type]).to eq("receipt")
            expect(inertia.props[:customer_emails][0][:id]).to eq purchase.external_id
            expect(inertia.props[:customer_emails][0][:name]).to eq "Receipt"
            expect(inertia.props[:customer_emails][0][:state]).to eq "Opened"
            expect(inertia.props[:customer_emails][0][:state_at]).to be_present
            expect(inertia.props[:customer_emails][0][:url]).to eq receipt_purchase_url(purchase.external_id, email: purchase.email)
          end

          it "returns success true with receipt and posts" do
            now = Time.current
            post1 = create(:installment, link: product, published_at: now - 10.seconds)
            post2 = create(:installment, link: product, published_at: now - 5.seconds)
            post3 = create(:installment, link: product, published_at: now - 1.second)

            create(:customer_email_info_opened, purchase: purchase)
            create(:creator_contacting_customers_email_info_delivered, installment: post1, purchase: purchase)
            create(:creator_contacting_customers_email_info_opened, installment: post2, purchase: purchase)
            create(:creator_contacting_customers_email_info_delivered, installment: post3, purchase: purchase)
            post_from_diff_user = create(:installment, link: product, seller: create(:user), published_at: Time.current)
            create(:creator_contacting_customers_email_info_delivered, installment: post_from_diff_user, purchase: purchase)
            get :index, params: { purchase_id: purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 4

            expect(inertia.props[:customer_emails][0][:type]).to eq("receipt")
            expect(inertia.props[:customer_emails][0][:id]).to eq purchase.external_id
            expect(inertia.props[:customer_emails][0][:state]).to eq "Opened"
            expect(inertia.props[:customer_emails][0][:url]).to eq receipt_purchase_url(purchase.external_id, email: purchase.email)

            expect(inertia.props[:customer_emails][1][:type]).to eq("post")
            expect(inertia.props[:customer_emails][1][:id]).to eq post3.external_id
            expect(inertia.props[:customer_emails][1][:state]).to eq "Delivered"

            expect(inertia.props[:customer_emails][2][:type]).to eq("post")
            expect(inertia.props[:customer_emails][2][:id]).to eq post2.external_id
            expect(inertia.props[:customer_emails][2][:state]).to eq "Opened"

            expect(inertia.props[:customer_emails][3][:type]).to eq("post")
            expect(inertia.props[:customer_emails][3][:id]).to eq post1.external_id
            expect(inertia.props[:customer_emails][3][:state]).to eq "Delivered"
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

            get :index, params: { purchase_id: original_purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 4

            expect(inertia.props[:customer_emails][0][:type]).to eq("receipt")
            expect(inertia.props[:customer_emails][0][:id]).to eq original_purchase.external_id
            expect(inertia.props[:customer_emails][0][:name]).to eq "Receipt"
            expect(inertia.props[:customer_emails][0][:state]).to eq "Opened"
            expect(inertia.props[:customer_emails][0][:url]).to eq receipt_purchase_url(original_purchase.external_id, email: original_purchase.email)

            expect(inertia.props[:customer_emails][1][:type]).to eq("receipt")
            expect(inertia.props[:customer_emails][1][:id]).to eq recurring_purchase.external_id
            expect(inertia.props[:customer_emails][1][:name]).to eq "Receipt"
            expect(inertia.props[:customer_emails][1][:state]).to eq "Opened"
            expect(inertia.props[:customer_emails][1][:url]).to eq receipt_purchase_url(recurring_purchase.external_id, email: recurring_purchase.email)

            expect(inertia.props[:customer_emails][2][:type]).to eq("post")
            expect(inertia.props[:customer_emails][2][:id]).to eq second_post.external_id
            expect(inertia.props[:customer_emails][2][:state]).to eq "Opened"

            expect(inertia.props[:customer_emails][3][:type]).to eq("post")
            expect(inertia.props[:customer_emails][3][:id]).to eq first_post.external_id
            expect(inertia.props[:customer_emails][3][:state]).to eq "Delivered"
          end

          it "includes receipts for free trial original purchases" do
            product = create(:membership_product, :with_free_trial_enabled, user: seller)
            original_purchase = create(:membership_purchase, link: product, seller:, is_free_trial_purchase: true, purchase_state: "not_charged")
            create(:customer_email_info_opened, purchase: original_purchase)

            get :index, params: { purchase_id: original_purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 1

            email_info = inertia.props[:customer_emails][0]
            expect(email_info[:type]).to eq("receipt")
            expect(email_info[:id]).to eq original_purchase.external_id
            expect(email_info[:name]).to eq "Receipt"
            expect(email_info[:state]).to eq "Opened"
            expect(email_info[:url]).to eq receipt_purchase_url(original_purchase.external_id, email: original_purchase.email)
          end
        end

        context "when purchase uses a charge receipt" do
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
            get :index, params: { purchase_id: purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 1

            email_info = inertia.props[:customer_emails][0]
            expect(email_info[:type]).to eq("receipt")
            expect(email_info[:id]).to eq purchase.external_id
            expect(email_info[:name]).to eq "Receipt"
            expect(email_info[:state]).to eq "Opened"
            expect(email_info[:url]).to eq receipt_purchase_url(purchase.external_id, email: purchase.email)
          end
        end

        context "for bundle purchase" do
          include_context "customer drawer missed posts setup"
          include_context "with bundle purchase setup", with_posts: true

          let!(:bundle_email) { create(:creator_contacting_customers_email_info_delivered, installment: bundle_post, purchase: bundle_purchase) }
          let!(:product_a_email) { create(:creator_contacting_customers_email_info_delivered, installment: regular_post_product_a, purchase: bundle_purchase.product_purchases.find_by(link: product_a)) }
          let!(:product_b_email) { create(:creator_contacting_customers_email_info_delivered, installment: regular_post_product_b, purchase: bundle_purchase.product_purchases.find_by(link: product_b)) }

          it "returns receipt only for bundle purchase" do
            get :index, params: { purchase_id: bundle_purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 2
            expect(inertia.props[:customer_emails].map { _1.values_at(:type, :id) }).to eq([["receipt", bundle_purchase.external_id], ["post", bundle_post.external_id]])
          end

          it "doesn't return receipt for bundle product purchase" do
            product_a_purchase = bundle_purchase.product_purchases.find_by(link: product_a)
            product_b_purchase = bundle_purchase.product_purchases.find_by(link: product_b)

            get :index, params: { purchase_id: product_a_purchase.external_id }
            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 1
            expect(inertia.props[:customer_emails].map { _1.values_at(:type, :id) }).to eq([["post", regular_post_product_a.external_id]])

            get :index, params: { purchase_id: product_b_purchase.external_id }
            expect(response).to be_successful
            expect(inertia.props[:customer_emails].count).to eq 1
            expect(inertia.props[:customer_emails].map { _1.values_at(:type, :id) }).to eq([["post", regular_post_product_b.external_id]])
          end
        end
      end

      context "workflows" do
        include_context "customer drawer missed posts setup"
        include_context "with bundle purchase setup", with_posts: true

        let!(:audience_workflow_post) { create(:audience_installment, :published, workflow: create(:audience_workflow, :published, seller:), seller:) }

        before do
          workflow_post_product_a.workflow.update!(name: "Alpha Workflow")
          seller_workflow.update!(name: "Beta Workflow")
          audience_workflow_post.workflow.update!(name: "Omega Workflow")
          bundle_workflow.update!(name: "Gamma Workflow")
          workflow_post_product_a_variant.workflow.update!(name: "Delta Workflow")
          request.headers["X-Inertia-Partial-Data"] = "workflows"
        end

        it "returns alive and published sorted by name" do
          get :index, params: { purchase_id: purchase.external_id }

          expect(response).to be_successful
          expect(inertia.props[:workflows].map { |w| w.values_at(:label, :id) }).to eq([["Alpha Workflow", workflow_post_product_a.workflow.external_id], ["Beta Workflow", seller_workflow.external_id], ["Omega Workflow", audience_workflow_post.workflow.external_id]])
        end

        it "returns variant workflows and published sorted by name" do
          purchase_with_product_a_variant = create(:purchase, link: product_a, variant_attributes: [product_a_variant], seller:)
          get :index, params: { purchase_id: purchase_with_product_a_variant.external_id }

          expect(response).to be_successful
          expect(inertia.props[:workflows].map { |w| w[:id] })
          expect(inertia.props[:workflows].map { |w| w.values_at(:label, :id) }).to eq([["Alpha Workflow", workflow_post_product_a.workflow.external_id], ["Beta Workflow", seller_workflow.external_id], ["Delta Workflow", workflow_post_product_a_variant.workflow.external_id], ["Omega Workflow", audience_workflow_post.workflow.external_id]])
        end

        context "for bundle purchase" do
          it "returns workflows for bundle" do
            get :index, params: { purchase_id: bundle_purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:workflows].map { |w| w[:id] }).to eq([seller_workflow.external_id, bundle_workflow.external_id, audience_workflow_post.workflow.external_id])
          end

          it "returns workflows for bundle purchase product" do
            product_a_purchase = bundle_purchase.product_purchases.find_by(link: product_a)
            get :index, params: { purchase_id: product_a_purchase.external_id }

            expect(response).to be_successful
            expect(inertia.props[:workflows].map { |w| w[:id] }).to eq([
                                                                         workflow_post_product_a.workflow.external_id,
                                                                         seller_workflow.external_id,
                                                                         workflow_post_product_a_variant.workflow.external_id,
                                                                         audience_workflow_post.workflow.external_id
                                                                       ])
          end
        end
      end

      context "missed_posts" do
        include_context "customer drawer missed posts setup"

        before do
          request.headers["X-Inertia-Partial-Data"] = "missed_posts"
        end

        it "returns only installments, not receipts" do
          expect(Installment).to receive(:missed_for_purchase).with(purchase, workflow_id: nil).and_call_original
          create(:customer_email_info, purchase:)

          get :index, params: { purchase_id: purchase.external_id }

          expect(response).to be_successful
          expect(inertia.props[:missed_posts]).to be_an(Array)
          expect(inertia.props[:missed_posts]).to all(include(:id, :name, :url, :published_at))
          expect(inertia.props[:missed_posts].length).to eq(6)
          expect(inertia.props[:missed_posts].map { _1.values_at(:id, :name) }).to eq([
                                                                                        [workflow_post_product_a.external_id, workflow_post_product_a.name],
                                                                                        [regular_post_product_a.external_id, regular_post_product_a.name],
                                                                                        [seller_post_with_bought_products_filter_product_a_and_c.external_id, seller_post_with_bought_products_filter_product_a_and_c.name],
                                                                                        [seller_workflow_post_to_all_customers.external_id, seller_workflow_post_to_all_customers.name],
                                                                                        [seller_post_to_all_customers.external_id, seller_post_to_all_customers.name],
                                                                                        [audience_post.external_id, audience_post.name]
                                                                                      ])
          expect(inertia.props[:missed_posts]).not_to include(hash_including(type: "receipt"))

          expect(Installment).to receive(:missed_for_purchase).with(purchase, workflow_id: workflow_post_product_a.workflow.external_id).and_call_original
          get :index, params: { purchase_id: purchase.external_id, workflow_id: workflow_post_product_a.workflow.external_id }

          expect(inertia.props[:missed_posts].map { _1[:id] }).to eq([workflow_post_product_a.external_id])
        end

        context "for bundle purchase" do
          include_context "with bundle purchase setup", with_posts: true

          it "returns only posts for bundle purchase" do
            expect(Installment).to receive(:missed_for_purchase).with(bundle_purchase, workflow_id: nil).and_call_original
            get :index, params: { purchase_id: bundle_purchase.external_id }

            expect(inertia.props[:missed_posts].map { _1[:id] }).to eq([
                                                                         bundle_workflow_post.external_id,
                                                                         bundle_post.external_id,
                                                                         seller_workflow_post_to_all_customers.external_id,
                                                                         seller_post_to_all_customers.external_id,
                                                                         audience_post.external_id
                                                                       ])

            expect(Installment).to receive(:missed_for_purchase).with(bundle_purchase, workflow_id: bundle_workflow.external_id).and_call_original
            get :index, params: { purchase_id: bundle_purchase.external_id, workflow_id: bundle_workflow.external_id }

            expect(inertia.props[:missed_posts].map { _1[:id] }).to eq([bundle_workflow_post.external_id])
          end

          it "returns only posts for bundle purchase product" do
            bundle_purchase_product_a = bundle_purchase.product_purchases.find_by(link: product_a)
            expect(Installment).to receive(:missed_for_purchase).with(bundle_purchase_product_a, workflow_id: nil).and_call_original
            get :index, params: { purchase_id: bundle_purchase_product_a.external_id }

            expect(inertia.props[:missed_posts].map { _1[:id] }).to eq([
                                                                         workflow_post_product_a_variant.external_id,
                                                                         workflow_post_product_a.external_id,
                                                                         regular_post_product_a_variant.external_id,
                                                                         regular_post_product_a.external_id,
                                                                         seller_post_with_bought_variants_filter_product_a_and_c_variant.external_id,
                                                                         seller_post_with_bought_products_filter_product_a_and_c.external_id,
                                                                         seller_workflow_post_to_all_customers.external_id,
                                                                         seller_post_to_all_customers.external_id,
                                                                         audience_post.external_id
                                                                       ])

            expect(Installment).to receive(:missed_for_purchase).with(bundle_purchase_product_a, workflow_id: workflow_post_product_a.workflow.external_id).and_call_original
            get :index, params: { purchase_id: bundle_purchase_product_a.external_id, workflow_id: workflow_post_product_a.workflow.external_id }

            expect(inertia.props[:missed_posts].map { _1[:id] }).to eq([workflow_post_product_a.external_id])
          end
        end
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

    context "when seller is suspended for TOS violation" do
      let(:admin_user) { create(:user) }
      let!(:product) { create(:product, user: seller) }

      before do
        seller.flag_for_tos_violation(author_id: admin_user.id, product_id: product.id)
        seller.suspend_for_tos_violation(author_id: admin_user.id)
        sign_in seller
        cookies.encrypted[:current_seller_id] = seller.id
        # NOTE: The invalidate_active_sessions! callback from suspending the user, interferes
        # with the login mechanism, this is a hack get the `sign_in user` method work correctly
        request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i
        index_model_records(Purchase)
      end

      it "renders successfully" do
        get :index

        expect(response).to be_successful
        expect(inertia.component).to eq("Customers/Index")
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
