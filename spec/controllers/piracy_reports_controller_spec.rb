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

    describe "GET index" do
      it "lists only the seller's reports, newest first" do
        older = create(:piracy_report, seller:, product:, url: "https://example.net/older")
        newer = create(:piracy_report, :awaiting_signature, seller:, product:, url: "https://example.net/newer")
        create(:piracy_report)

        get :index

        expect(response).to be_successful
        expect(inertia.component).to eq("PiracyReports/Index")
        expect(inertia.props[:reports].map { _1[:id] }).to eq([newer.external_id, older.external_id])
        expect(inertia.props[:reports].first).to include(product_name: product.name, url: "https://example.net/newer", state: "awaiting_signature", outcome: nil)
        expect(inertia.props[:can_report]).to be(true)
        expect(inertia.props[:archived_tab_visible]).to be(false)
      end

      it "still lists past reports when the seller can no longer file one" do
        create(:piracy_report, seller:, product:)
        Feature.deactivate_user(:piracy_reports, seller)

        get :index

        expect(inertia.props[:reports].size).to eq(1)
        expect(inertia.props[:can_report]).to be(false)
      end
    end

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
        expect(inertia.props[:confirmations]).to eq(PiracyReport::SIGNATURE_CONFIRMATIONS.map { |key, text| { key:, text: } })
        expect(inertia.props[:confirmations_version]).to eq(PiracyReport::SIGNATURE_STATEMENT_VERSION)
      end

      it "renders the history and the restoration window of a disputed report" do
        report = create(:piracy_report, :signed, seller:, product:, state: "counter_noticed", screened_at: Time.utc(2026, 10, 2, 9),
                                                 sent_at: Time.utc(2026, 10, 5, 9), delivered_at: Time.utc(2026, 10, 5, 10),
                                                 counter_notice_body: "Licensed.", counter_notice_received_on: Date.new(2026, 10, 7))

        get :show, params: { id: report.external_id }

        expect(inertia.props[:report][:restoration_window]).to eq(["2026-10-21", "2026-10-27"])
        expect(inertia.props[:report][:history].map { _1[:event] }).to eq(%i[filed confirmed signed sent delivered counter_notice])
        expect(inertia.props[:report][:history].last).to eq(event: :counter_notice, at: "2026-10-07")
      end

      it "shows a declined report as declined in the history" do
        report = create(:piracy_report, seller:, product:, state: "declined", screening_verdict: "fail", screened_at: 1.day.ago)

        get :show, params: { id: report.external_id }

        expect(inertia.props[:report][:history].map { _1[:event] }).to eq(%i[filed declined])
      end

      it "ends the history of a cancelled report with its closing" do
        report = create(:piracy_report, :awaiting_signature, seller:, product:, screened_at: 2.days.ago)
        report.cancel!

        get :show, params: { id: report.external_id }

        expect(inertia.props[:report][:history].map { _1[:event] }).to eq(%i[filed confirmed closed])
      end

      it "says when a person, not the agent, is checking the page" do
        report = create(:piracy_report, seller:, product:, state: "screening", screening_verdict: "review", screened_at: 1.day.ago)

        get :show, params: { id: report.external_id }
        expect(inertia.props[:report]).to include(waiting_on_person: true)
        expect(inertia.props[:report][:history].map { _1[:event] }).to eq(%i[filed])

        report.update!(screening_verdict: nil)
        get :show, params: { id: report.external_id }
        expect(inertia.props[:report]).to include(waiting_on_person: false)
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

    describe "POST cancel" do
      it "cancels a signed report before it is sent, so the send job skips it" do
        report = create(:piracy_report, :signed, seller:, product:)

        post :cancel, params: { id: report.external_id }

        expect(response).to redirect_to(piracy_report_path(report.external_id))
        expect(flash[:notice]).to eq("Report cancelled. Nothing was sent.")
        expect(report.reload.state).to eq("cancelled")
        expect(PiracyReports::SendService.new(report:).call.errors).to include("The report is not signed")
      end

      it "leaves a sent report alone" do
        report = create(:piracy_report, :signed, seller:, product:, state: "sent", sent_at: 1.hour.ago)

        post :cancel, params: { id: report.external_id }

        expect(flash[:alert]).to eq("This notice was already sent, so the report cannot be cancelled.")
        expect(report.reload.state).to eq("sent")
      end

      it "does not cancel another seller's report" do
        report = create(:piracy_report, :signed)

        post :cancel, params: { id: report.external_id }

        expect(response).to redirect_to(products_path)
        expect(report.reload.state).to eq("signed")
      end
    end

    describe "POST sign" do
      let(:confirmations) { PiracyReport::SIGNATURE_CONFIRMATIONS.keys }

      it "records the signature, the confirmations version and the IP, and signs the notice" do
        report = create(:piracy_report, :awaiting_signature, seller:, product:)
        request.remote_ip = "203.0.113.7"

        post :sign, params: { id: report.external_id, signed_by_name: "  Jane  Doe ", confirmations:, confirmations_version: PiracyReport::SIGNATURE_STATEMENT_VERSION }

        expect(report.reload).to have_attributes(
          state: "signed",
          signed_by_name: "Jane Doe",
          signed_ip: "203.0.113.7",
          signature_statement_version: PiracyReport::SIGNATURE_STATEMENT_VERSION
        )
        expect(report.notice_text).to start_with("Notice text\n\nSigned: /s/ Jane Doe, ")
        expect(report.notice_digest).to eq(Digest::SHA256.hexdigest(report.notice_text))
        expect(response).to redirect_to(piracy_report_path(report.external_id))
      end

      it "refuses to sign when a confirmation is unchecked" do
        report = create(:piracy_report, :awaiting_signature, seller:, product:)

        post :sign, params: { id: report.external_id, signed_by_name: "Jane Doe", confirmations: confirmations.first(4), confirmations_version: PiracyReport::SIGNATURE_STATEMENT_VERSION }

        expect(report.reload.state).to eq("awaiting_signature")
        expect(flash[:alert]).to include("Check every confirmation to sign")
      end

      it "refuses a blank name" do
        report = create(:piracy_report, :awaiting_signature, seller:, product:)

        post :sign, params: { id: report.external_id, signed_by_name: "   ", confirmations:, confirmations_version: PiracyReport::SIGNATURE_STATEMENT_VERSION }

        expect(report.reload.state).to eq("awaiting_signature")
        expect(flash[:alert]).to include("full legal name")
      end

      it "refuses a report that is not waiting for a signature" do
        report = create(:piracy_report, seller:, product:)

        post :sign, params: { id: report.external_id, signed_by_name: "Jane Doe", confirmations:, confirmations_version: PiracyReport::SIGNATURE_STATEMENT_VERSION }

        expect(report.reload.state).to eq("requested")
        expect(flash[:alert]).to include("not ready to sign")
      end

      it "does not sign another seller's report" do
        report = create(:piracy_report, :awaiting_signature)

        post :sign, params: { id: report.external_id, signed_by_name: "Jane Doe", confirmations:, confirmations_version: PiracyReport::SIGNATURE_STATEMENT_VERSION }

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

      post :sign, params: { id: report.external_id, signed_by_name: "Jane Doe", confirmations: PiracyReport::SIGNATURE_CONFIRMATIONS.keys, confirmations_version: PiracyReport::SIGNATURE_STATEMENT_VERSION }
      expect(report.reload.state).to eq("awaiting_signature")
    end

    it "cannot cancel the owner's report" do
      report = create(:piracy_report, :signed, seller:, product:)

      post :cancel, params: { id: report.external_id }

      expect(response).to redirect_to(dashboard_url)
      expect(report.reload.state).to eq("signed")
    end

    it "cannot list the owner's reports" do
      get :index

      expect(response).to redirect_to(dashboard_url)
    end
  end
end
