# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe DashboardController do
  render_views

  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_user) }

  before do
    create(:user_compliance_info, user: seller, first_name: "Gumbot")
  end

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { :dashboard }
    end

    def expect_dashboard_data_in_inertia_response(expected_data = {})
      data_page_match = response.body.match(/data-page="([^"]*)"/)
      expect(data_page_match).to be_present, "Expected Inertia.js data-page attribute"

      decoded_content = CGI.unescapeHTML(data_page_match[1])
      json_data = JSON.parse(decoded_content)

      creator_home = json_data["props"]["creator_home"]
      expect(creator_home).to be_present, "Expected creator_home in Inertia.js response"

      expected_data.each do |key, value|
        expect(creator_home[key.to_s]).to eq(value), "Expected #{key} to be #{value}, but got #{creator_home[key.to_s]}"
      end
    end

    context "when seller has no activity" do
      it "renders the page" do
        get :index

        expect(response).to be_successful

        expect(response.body).to include("data-page")
        expect(response.body).to include("Dashboard/index")

        expect_dashboard_data_in_inertia_response(
          has_sale: false,
          sales: [],
          activity_items: []
        )
      end
    end

    context "when seller has products, but no sales" do
      before do
        create(:product, user: seller)
      end

      it "renders no sales text" do
        get :index

        expect(response).to be_successful

        expect(response.body).to include("data-page")
        expect(response.body).to include("Dashboard/index")

        expect_dashboard_data_in_inertia_response(
          has_sale: false
        )

        data_page_match = response.body.match(/data-page="([^"]*)"/)
        decoded_content = CGI.unescapeHTML(data_page_match[1])
        json_data = JSON.parse(decoded_content)
        creator_home = json_data["props"]["creator_home"]

        expect(creator_home["sales"]).to be_present
        expect(creator_home["sales"].first["sales"]).to eq(0)
      end
    end

    context "when seller has purchases" do
      let(:product) { create(:product, user: seller, price_cents: 150) }
      let(:follower) { create(:follower, user: seller, confirmed_at: 7.hours.ago) }

      before do
        create(:purchase_event, purchase: create(:purchase, link: product), created_at: Time.current)
        follower.update!(confirmed_at: nil, deleted_at: 1.hour.ago)
      end

      around do |example|
        travel_to Time.utc(2023, 6, 4) do
          example.run
        end
      end

      it "renders the purchase", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        get :index

        expect(response).to be_successful

        expect(response.body).to include("data-page")
        expect(response.body).to include("Dashboard/index")

        data_page_match = response.body.match(/data-page="([^"]*)"/)
        if data_page_match
          decoded_content = CGI.unescapeHTML(data_page_match[1])
          json_data = JSON.parse(decoded_content)
          creator_home = json_data["props"]["creator_home"]
          puts "Creator home with purchases:"
          puts "  has_sale: #{creator_home['has_sale']}"
          puts "  sales count: #{creator_home['sales']&.length}"
          puts "  activity_items count: #{creator_home['activity_items']&.length}"
          puts "  balances: #{creator_home['balances']}"
          puts "  getting_started_stats: #{creator_home['getting_started_stats']}"
        end

        expect_dashboard_data_in_inertia_response(
          has_sale: true
        )
      end
    end

    context "when seller has no alive products" do
      let(:product) { create(:product, user: seller) }

      before do
        product.delete!
      end

      it "renders appropriate text" do
        get :index

        expect(response).to be_successful

        # For Inertia.js, we should check for the data-page attribute and component name
        expect(response.body).to include("data-page")
        expect(response.body).to include("Dashboard/index")

        # Check that the dashboard data shows no products (since product was deleted)
        expect_dashboard_data_in_inertia_response(
          has_sale: false,
          sales: []
        )
      end
    end

    context "when seller has completed all 'Getting started' items" do
      before do
        create(:product, user: seller)
        create(:workflow, seller:)
        create(:active_follower, user: seller)
        create(:purchase, :from_seller, seller:)
        create(:payment_completed, user: seller)
        create(:installment, seller:, send_emails: true)

        small_bets_product = create(:product)
        create(:purchase, purchaser: seller, link: small_bets_product)
        stub_const("ENV", ENV.to_hash.merge("SMALL_BETS_PRODUCT_ID" => small_bets_product.id))
      end

      it "doesn't render `Getting started` text"  do
        get :index

        expect(response.body).to_not have_text("We're here to help you get paid for your work.")
        expect(response.body).to_not have_text("Getting started")
      end
    end

    context "when seller is suspended for TOS" do
      let(:admin_user) { create(:user) }
      let!(:product) { create(:product, user: seller) }

      before do
        create(:user_compliance_info, user: seller)
        seller.flag_for_tos_violation(author_id: admin_user.id, product_id: product.id)
        seller.suspend_for_tos_violation(author_id: admin_user.id)
        # NOTE: The invalidate_active_sessions! callback from suspending the user, interferes
        # with the login mechanism, this is a hack get the `sign_in user` method work correctly
        request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i
      end

      it "redirects to the products_path" do
        get :index

        expect(response).to redirect_to products_path
      end
    end
  end

  describe "GET customers_count" do
    it_behaves_like "authorize called for action", :get, :customers_count do
      let(:record) { :dashboard }
    end

    it "returns the formatted number of customers" do
      allow_any_instance_of(User).to receive(:all_sales_count).and_return(123_456)

      get :customers_count

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["value"]).to eq("123,456")
    end
  end

  describe "GET total_revenue" do
    it_behaves_like "authorize called for action", :get, :total_revenue do
      let(:record) { :dashboard }
    end

    it "returns the formatted revenue" do
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(123_456)

      get :total_revenue

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["value"]).to eq("$1,234.56")
    end
  end

  describe "GET active_members_count" do
    it_behaves_like "authorize called for action", :get, :active_members_count do
      let(:record) { :dashboard }
    end

    it "returns the formatted revenue" do
      allow_any_instance_of(User).to receive(:active_members_count).and_return(123_456)

      get :active_members_count

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["value"]).to eq("123,456")
    end
  end

  describe "GET monthly_recurring_revenue" do
    it_behaves_like "authorize called for action", :get, :monthly_recurring_revenue do
      let(:record) { :dashboard }
    end

    it "returns the formatted revenue" do
      allow_any_instance_of(User).to receive(:monthly_recurring_revenue).and_return(123_456)

      get :monthly_recurring_revenue

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["value"]).to eq("$1,234.56")
    end
  end

  describe "GET download_tax_form" do
    it_behaves_like "authorize called for action", :get, :download_tax_form do
      let(:record) { :dashboard }
    end

    it "redirects to the 1099 form download url if present" do
      allow_any_instance_of(User).to receive(:tax_form_1099_download_url).and_return("https://gumroad.com/")

      get :download_tax_form

      expect(response).to redirect_to("https://gumroad.com/")
    end

    it "redirects to dashboard if form download url is not present" do
      allow_any_instance_of(User).to receive(:tax_form_1099_download_url).and_return(nil)

      get :download_tax_form

      expect(response).to redirect_to(dashboard_url(host: UrlService.domain_with_protocol))
      expect(flash[:alert]).to eq("A 1099 form for #{Time.current.prev_year.year} was not filed for your account.")
    end
  end
end
