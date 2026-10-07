# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe PiracyReportsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:product) { create(:product, user: seller, price_cents: 0) }

  before do
    create(:user_compliance_info, user: seller)
    Feature.activate_user(:piracy_reports, seller)
    create(:payment_completed, user: seller)
    # The controller resolves its own seller object, so the store agent's sales bar is stubbed on
    # the class, as the store agent's own controller specs do.
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT)
    create(:purchase, link: product)
  end

  context "with user signed in as admin for seller" do
    include_context "with user signed in as admin for seller"

    describe "GET new" do
      it "renders the form with the product and no eligibility errors" do
        get :new, params: { product_id: product.unique_permalink }

        expect(response).to be_successful
        expect(inertia.component).to eq("PiracyReports/New")
        expect(inertia.props[:product]).to eq(
          id: product.unique_permalink,
          name: product.name,
          url: product.long_url
        )
        expect(inertia.props[:eligibility_errors]).to eq([])
        expect(inertia.props[:monthly_limit]).to eq(PiracyReport::MONTHLY_LIMIT)
      end

      it "lists the reasons the seller cannot report yet" do
        seller.update!(confirmed_at: nil)

        get :new, params: { product_id: product.unique_permalink }

        expect(inertia.props[:eligibility_errors]).to include(PiracyReports::Eligibility.store_agent_gate_error)
      end

      it "redirects when the product belongs to someone else" do
        get :new, params: { product_id: create(:product).unique_permalink }

        expect(response).to redirect_to(products_path)
        expect(flash[:alert]).to eq("Product not found")
      end

      it "redirects when the seller does not have the flag" do
        Feature.deactivate_user(:piracy_reports, seller)

        get :new, params: { product_id: product.unique_permalink }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
      end
    end

    describe "POST create" do
      it "files the report against the product and sends the seller to it" do
        post :create, params: { product_id: product.unique_permalink, url: "https://example.net/design-course" }

        report = PiracyReport.last
        expect(report).to have_attributes(
          seller_id: seller.id,
          product_id: product.id,
          url: "https://example.net/design-course",
          source: "dashboard",
          state: "requested"
        )
        expect(response).to redirect_to(piracy_report_path(report.external_id))
      end

      it "sends the seller back to the form with the reason when the URL is unusable" do
        post :create, params: { product_id: product.unique_permalink, url: "not-a-url" }

        expect(PiracyReport.count).to eq(0)
        expect(response).to redirect_to(new_piracy_report_path(product_id: product.unique_permalink))
        expect(flash[:alert]).to eq("The URL must start with http:// or https://")
      end

      it "refuses a page on Gumroad" do
        post :create, params: { product_id: product.unique_permalink, url: product.long_url }

        expect(PiracyReport.count).to eq(0)
        expect(flash[:alert]).to eq(PiracyReport::HOSTED_ON_GUMROAD_ERROR)
      end

      it "refuses once the seller has used the monthly limit" do
        PiracyReport::MONTHLY_LIMIT.times do |i|
          create(:piracy_report, seller:, product:, url: "https://example.net/page-#{i}")
        end

        post :create, params: { product_id: product.unique_permalink, url: "https://example.net/design-course" }

        expect(PiracyReport.count).to eq(PiracyReport::MONTHLY_LIMIT)
        expect(flash[:alert]).to eq("The monthly limit of #{PiracyReport::MONTHLY_LIMIT} reports has been reached")
      end

      it "refuses when the seller does not have the flag" do
        Feature.deactivate_user(:piracy_reports, seller)

        post :create, params: { product_id: product.unique_permalink, url: "https://example.net/design-course" }

        expect(PiracyReport.count).to eq(0)
        expect(response).to redirect_to(dashboard_url)
      end
    end

    describe "GET show" do
      it "renders the notice when the report is waiting for a signature" do
        report = create(:piracy_report, :awaiting_signature, seller:, product:)

        get :show, params: { id: report.external_id }

        expect(response).to be_successful
        expect(inertia.component).to eq("PiracyReports/Show")
        expect(inertia.props[:report]).to include(
          id: report.external_id,
          state: "awaiting_signature",
          notice_text: "Notice text",
          signed_at: nil
        )
      end

      it "renders the review state before screening finishes" do
        report = create(:piracy_report, seller:, product:)

        get :show, params: { id: report.external_id }

        expect(inertia.props[:report]).to include(state: "requested", notice_text: nil)
      end

      it "does not render another seller's report" do
        report = create(:piracy_report)

        get :show, params: { id: report.external_id }

        expect(response).to redirect_to(products_path)
        expect(flash[:alert]).to eq("Report not found")
      end
    end

    describe "POST sign" do
      it "records the signature and freezes the notice" do
        report = create(:piracy_report, :awaiting_signature, seller:, product:)

        post :sign, params: { id: report.external_id, signed_by_name: "  Jane  Doe " }

        expect(report.reload).to have_attributes(
          state: "signed",
          signed_by_name: "Jane Doe"
        )
        expect(report.signed_at).to be_present
        expect(report.notice_text).to eq("Notice text")
        expect(report.notice_digest).to eq(Digest::SHA256.hexdigest("Notice text"))
        expect(response).to redirect_to(piracy_report_path(report.external_id))
      end

      it "refuses a blank name" do
        report = create(:piracy_report, :awaiting_signature, seller:, product:)

        post :sign, params: { id: report.external_id, signed_by_name: "   " }

        expect(report.reload.state).to eq("awaiting_signature")
        expect(flash[:alert]).to include("full legal name")
      end

      it "refuses a report that is not waiting for a signature" do
        report = create(:piracy_report, seller:, product:)

        post :sign, params: { id: report.external_id, signed_by_name: "Jane Doe" }

        expect(report.reload.state).to eq("requested")
        expect(flash[:alert]).to include("not ready to sign")
      end

      it "does not sign another seller's report" do
        report = create(:piracy_report, :awaiting_signature)

        post :sign, params: { id: report.external_id, signed_by_name: "Jane Doe" }

        expect(report.reload.state).to eq("awaiting_signature")
        expect(response).to redirect_to(products_path)
      end
    end
  end

  # A support (or marketing/accountant) team member can switch into the owner's account, so this
  # has to sit outside the admin context above: each role context creates a team membership for
  # `seller`, and TeamMembership allows only one membership per (user, seller) pair.
  context "with user signed in as support for seller" do
    include_context "with user signed in as support for seller"

    it "cannot read or sign the owner's notice" do
      report = create(:piracy_report, :awaiting_signature, seller:, product:)

      get :show, params: { id: report.external_id }
      expect(response).to redirect_to(dashboard_url)

      post :sign, params: { id: report.external_id, signed_by_name: "Jane Doe" }
      expect(report.reload.state).to eq("awaiting_signature")
    end
  end
end
