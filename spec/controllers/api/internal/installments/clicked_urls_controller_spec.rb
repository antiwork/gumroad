# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::Installments::ClickedUrlsController do
  let(:seller) { create(:user) }
  let(:installment) { create(:installment, seller:, published_at: 1.day.ago) }

  include_context "with user signed in as accountant for seller"

  describe "GET show" do
    it_behaves_like "authentication required for action", :get, :show do
      let(:request_params) { { id: installment.external_id } }
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { installment }
      let(:policy_method) { :index? }
      let(:request_params) { { id: record.external_id } }
    end

    it "returns 404 for another seller's post" do
      get :show, params: { id: create(:installment, published_at: 1.day.ago).external_id }

      expect(response).to have_http_status(:not_found)
    end

    it "returns the clicked URLs, most clicked first" do
      [["M.a", "[1]"], ["M.b", "[2]"]].each do |mailer_method, mailer_args|
        EmailEngagementDynamoStore.record_click(installment_id: installment.id, mailer_method:, mailer_args:, click_url: "https://example.com/b")
      end
      EmailEngagementDynamoStore.record_click(installment_id: installment.id, mailer_method: "M.a", mailer_args: "[1]", click_url: EmailEventInfo::VIEW_ATTACHMENTS_URL)

      get :show, params: { id: installment.external_id }

      expect(response).to be_successful
      expect(response.parsed_body).to eq(
        "clicked_urls" => [
          { "url" => "example.com/b", "count" => 2 },
          { "url" => "View content", "count" => 1 },
        ]
      )
    end
  end
end
