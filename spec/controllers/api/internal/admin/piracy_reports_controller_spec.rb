# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Admin::PiracyReportsController do
  let(:bot) { create(:admin_user) }
  let(:piracy_token) { AdminApiToken.mint!(actor_user_id: bot.id, scope: AdminApiToken::PIRACY_SCOPE) }

  before { request.headers["Authorization"] = "Bearer #{piracy_token}" }

  it "inherits from Api::Internal::Admin::BaseController and requires the piracy scope" do
    expect(described_class.superclass).to eq(Api::Internal::Admin::BaseController)
    expect(described_class.required_token_scope).to eq("piracy")
  end

  describe "authorization" do
    it "returns 401 without a token" do
      request.headers["Authorization"] = nil

      get :index

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for an unknown token" do
      request.headers["Authorization"] = "Bearer invalid-token"

      get :index

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 for a token with the admin scope" do
      request.headers["Authorization"] = "Bearer #{AdminApiToken.mint!(actor_user_id: bot.id)}"

      get :index

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["message"]).to eq("token scope does not allow this endpoint")
    end

    it "returns 401 for a revoked piracy token" do
      AdminApiToken.find_by!(token_hash: AdminApiToken.hash_token(piracy_token)).update!(revoked_at: Time.current)

      get :index

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET index" do
    it "lists reports and filters by state, user and updated_before" do
      old = create(:piracy_report, state: "screening")
      old.update_columns(updated_at: 1.hour.ago)
      recent = create(:piracy_report)

      get :index
      expect(response.parsed_body["reports"].pluck("report_id")).to contain_exactly(old.external_id, recent.external_id)

      get :index, params: { state: "screening" }
      expect(response.parsed_body["reports"].pluck("report_id")).to eq([old.external_id])

      get :index, params: { user_id: recent.seller.external_id }
      expect(response.parsed_body["reports"].pluck("report_id")).to eq([recent.external_id])

      get :index, params: { updated_before: 30.minutes.ago.iso8601 }
      expect(response.parsed_body["reports"].pluck("report_id")).to eq([old.external_id])
    end

    it "loads sellers and products in bulk, so the query count does not grow with the report count" do
      queries = lambda do
        count = 0
        counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/) }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get :index }
        count
      end
      create(:piracy_report)
      one_report = queries.call
      3.times { |i| create(:piracy_report, url: "https://example.net/copy-#{i}") }

      expect(queries.call).to eq(one_report)
    end

    it "treats nested filter values as text instead of raising" do
      create(:piracy_report)

      get :index, params: { state: { x: "y" }, limit: { a: 1 } }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["reports"]).to eq([])

      get :index, params: { user_id: { x: "y" } }
      expect(response).to have_http_status(:not_found)
    end

    it "pages with the after cursor, so reports beyond the first page stay reachable" do
      first, second, third = 3.times.map { |i| create(:piracy_report, url: "https://example.net/copy-#{i}") }

      get :index, params: { after: first.external_id }
      expect(response.parsed_body["reports"].pluck("report_id")).to eq([second.external_id, third.external_id])

      get :index, params: { after: third.external_id }
      expect(response.parsed_body["reports"]).to eq([])

      get :index, params: { after: "unknown" }
      expect(response).to have_http_status(:not_found)
    end

    it "returns 400 for an updated_before that is not a timestamp" do
      get :index, params: { updated_before: "yesterday-ish" }

      expect(response).to have_http_status(:bad_request)
    end

    it "returns 400 for an updated_before that looks like a date but is out of range" do
      get :index, params: { updated_before: "2026-13-01" }

      expect(response).to have_http_status(:bad_request)
    end

    it "returns 404 for an unknown user" do
      get :index, params: { user_id: "unknown" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET show" do
    it "returns the report with product facts from Rails records" do
      seller, product = create_piracy_seller_with_product
      report = create(:piracy_report, seller:, product:)

      get :show, params: { id: report.external_id }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["report"]
      expect(body).to include("report_id" => report.external_id, "state" => "requested", "user_id" => seller.external_id, "product_id" => product.external_id)
      expect(body["product"]).to include("name" => product.name, "successful_sales_count" => 1)
      expect(body["eligibility_errors"]).to eq([])
    end

    it "lists the reasons a seller is no longer eligible" do
      seller, product = create_piracy_seller_with_product
      report = create(:piracy_report, seller:, product:)
      Feature.deactivate_user(:piracy_reports, seller)

      get :show, params: { id: report.external_id }

      expect(response.parsed_body["report"]["eligibility_errors"]).to eq(["Piracy reports are not enabled for this seller"])
    end

    it "returns 404 for a nested id instead of raising" do
      get :show, params: { id: { a: 1 } }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for an unknown report" do
      get :show, params: { id: "unknown" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    let!(:seller_and_product) { create_piracy_seller_with_product }
    let(:seller) { seller_and_product.first }
    let(:product) { seller_and_product.last }
    let(:params) { { user_id: seller.external_id, product_id: product.external_id, url: "https://example.net/design-course", ticket_url: "https://helper.example.com/tickets/1" } }

    it "creates a support report and audits the write" do
      expect do
        post :create, params:
      end.to change { PiracyReport.count }.by(1).and change { AdminApiAuditLog.count }.by(1)

      expect(response).to have_http_status(:created)
      report = PiracyReport.last
      expect(report).to have_attributes(source: "support", state: "requested", seller:, product:, ticket_url: "https://helper.example.com/tickets/1")
      expect(report.events.sole.actor_id).to eq(bot.id)
      expect(AdminApiAuditLog.last).to have_attributes(action: "piracy_reports.create", target_external_id: seller.external_id)
    end

    it "returns 400 without a user_id" do
      post :create, params: params.except(:user_id)

      expect(response).to have_http_status(:bad_request)
    end

    it "returns 404 for a nested product_id instead of raising" do
      post :create, params: params.merge(product_id: { a: 1 })

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a product that is not the seller's" do
      post :create, params: params.merge(product_id: create(:product).external_id)

      expect(response).to have_http_status(:not_found)
    end

    it "returns 422 with the reasons when the seller is not eligible" do
      Feature.deactivate_user(:piracy_reports, seller)

      expect do
        post :create, params:
      end.not_to change { PiracyReport.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"]).to eq(["Piracy reports are not enabled for this seller"])
    end
  end

  describe "POST start_screening" do
    it "moves a requested report to screening and audits the write" do
      report = create(:piracy_report)

      expect do
        post :start_screening, params: { id: report.external_id }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(report.reload.state).to eq("screening")
      expect(AdminApiAuditLog.last).to have_attributes(action: "piracy_reports.start_screening", target_external_id: report.external_id)
    end

    it "returns 422 when another request started screening after this one loaded the report" do
      report = create(:piracy_report)
      allow(PiracyReport).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { PiracyReport.where(id: _1.id).update_all(state: "screening") }
      end

      post :start_screening, params: { id: report.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(report.reload.events.where(event: "start_screening")).to be_empty
      expect(AdminApiAuditLog.last).to have_attributes(action: "piracy_reports.start_screening", response_status: 422, error_class: nil)
    end

    it "returns 422 when the report is already being screened" do
      report = create(:piracy_report, :screening)

      post :start_screening, params: { id: report.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST screen" do
    let!(:seller_and_product) { create_piracy_seller_with_product }
    let(:seller) { seller_and_product.first }
    let(:product) { seller_and_product.last }
    let(:report) { create(:piracy_report, :screening, seller:, product:) }
    let(:checks) { PiracyReport::SCREENING_CHECKS.index_with { { passed: true, reason: "Matches the product." } } }
    let(:pass_params) do
      {
        id: report.external_id,
        verdict: "pass",
        checks:,
        recipient_kind: "site",
        recipient_name: "Example Net",
        recipient_email: "copyright@example.net",
        recipient_source_url: "https://example.net/copyright"
      }
    end

    it "passes the report, returns the rendered notice and audits the write" do
      expect do
        post :screen, params: pass_params
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["report"]
      expect(body["state"]).to eq("awaiting_signature")
      expect(body["notice_digest"]).to eq(Digest::SHA256.hexdigest(report.reload.notice_text))
      expect(AdminApiAuditLog.last).to have_attributes(action: "piracy_reports.screen", target_external_id: report.external_id)
    end

    it "never returns the rendered notice, which holds the seller's name, address and email" do
      post :screen, params: pass_params
      get :show, params: { id: report.external_id }

      expect(response.body).not_to include(seller.email)
      expect(response.body).not_to include(seller.alive_user_compliance_info.legal_entity_street_address)
      expect(response.parsed_body["report"]).not_to have_key("notice_text")
    end

    it "redacts the recipient email in the audit snapshot" do
      post :screen, params: pass_params

      expect(AdminApiAuditLog.last.params_snapshot["recipient_email"]).to eq("[REDACTED]")
    end

    it "declines the report on a fail verdict" do
      post :screen, params: { id: report.external_id, verdict: "fail", checks: { page_offers_work: { passed: false, reason: "Different course." } } }

      expect(response).to have_http_status(:ok)
      expect(report.reload.state).to eq("declined")
    end

    it "returns 422 with the errors for invalid input and leaves the report in screening" do
      post :screen, params: pass_params.merge(recipient_email: "not-an-email")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"]).to eq(["recipient_email is invalid"])
      expect(report.reload.state).to eq("screening")
    end

    it "returns 422 when the report is not being screened" do
      requested = create(:piracy_report, seller:, product:, url: "https://example.net/other")

      post :screen, params: pass_params.merge(id: requested.external_id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("The report is not being screened")
    end
  end
end
