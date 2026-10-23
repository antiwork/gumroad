# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::FeatureAnnouncementCampaignsController do
  let(:admin_user) { create(:admin_user, email: "operator@example.com") }
  let(:draft_params) do
    { key: "new_feature", audience: "piracy_reports", subject: "Try the new feature", reply_to: "support@gumroad.com",
      body: '<p>Hi creator,</p><p>Read the <a href="https://gumroad.com/help">guide</a>.</p>' }
  end

  def json = response.parsed_body

  describe "POST create" do
    include_examples "admin api authorization required", :post, :create

    before { request.headers["Authorization"] = "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}" }

    it "rejects the legacy shared admin token" do
      request.headers["Authorization"] = "Bearer test-admin-token"

      post :create, params: draft_params

      expect(response).to have_http_status(:unauthorized)
      expect(FeatureAnnouncementCampaign.count).to eq(0)
    end

    it "creates a draft and records the write" do
      post :create, params: draft_params

      expect(response).to have_http_status(:created)
      expect(json["campaign"]).to include("key" => "new_feature", "state" => "draft", "audience" => "piracy_reports", "approved_by" => nil)
      expect(AdminApiAuditLog.sole).to have_attributes(action: "feature_announcement_campaigns.create", target_id: FeatureAnnouncementCampaign.sole.id)
    end

    it "refuses an unknown audience, an outside Reply-To and an http link" do
      post :create, params: draft_params.merge(audience: "everyone", reply_to: "me@example.com", body: '<a href="http://example.com">x</a>')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["message"]).to include("Audience is not included in the list", "Reply to is invalid", "Body links must use https")
      expect(FeatureAnnouncementCampaign.count).to eq(0)
    end
  end

  describe "the lifecycle" do
    let!(:campaign) { create(:feature_announcement_campaign, :draft, **draft_params) }

    before { request.headers["Authorization"] = "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}" }

    it "previews, approves the previewed copy, and starts the send" do
      get :preview, params: { id: "new_feature" }

      expect(response).to have_http_status(:ok)
      expect(json["email"]).to include("subject" => "Try the new feature", "reply_to" => ["support@gumroad.com"], "from" => FeatureAnnouncementMailer::FROM)
      expect(json["email"]["html_body"]).to include("https://gumroad.com/help")
      html = Nokogiri::HTML(json["email"]["html_body"])
      expect(html.css("link[rel=stylesheet]")).to be_empty
      expect(html.at_css(".main")["style"]).to be_present
      expect(FeatureAnnouncementDelivery.count).to eq(0)
      digest = json["campaign"]["content_digest"]

      post :approve, params: { id: "new_feature", content_digest: digest }

      expect(response).to have_http_status(:ok)
      expect(json["campaign"]).to include("state" => "approved", "approved_by" => admin_user.external_id)

      expect { post :deliver, params: { id: "new_feature" } }.to change { SendFeatureAnnouncementCampaignJob.jobs.size }.by(1)

      expect(json["campaign"]["state"]).to eq("sending")
      expect(SendFeatureAnnouncementCampaignJob.jobs.last["args"]).to eq([campaign.id])
      expect(AdminApiAuditLog.pluck(:action)).to eq(%w[feature_announcement_campaigns.approve feature_announcement_campaigns.deliver])
    end

    it "previews the digest of the copy it rendered when the draft changes after the lookup" do
      allow(FeatureAnnouncementCampaign).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { FeatureAnnouncementCampaign.find(_1.id).update!(subject: "Edited meanwhile") }
      end

      get :preview, params: { id: "new_feature" }

      expect(json["email"]["subject"]).to eq("Edited meanwhile")
      expect(json["campaign"]["content_digest"]).to eq(campaign.reload.current_digest)
    end

    it "edits a draft" do
      patch :update, params: { id: "new_feature", subject: "Changed" }

      expect(response).to have_http_status(:ok)
      expect(campaign.reload.subject).to eq("Changed")
    end

    it "refuses to approve copy that changed after the preview" do
      digest = campaign.current_digest
      campaign.update!(subject: "Edited after the preview")

      post :approve, params: { id: "new_feature", content_digest: digest }

      expect(response).to have_http_status(:conflict)
      expect(json["message"]).to eq("the copy changed since the preview")
      expect(campaign.reload.state).to eq("draft")
    end

    it "refuses an edit when the campaign is approved after the request loaded it" do
      allow(FeatureAnnouncementCampaign).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { FeatureAnnouncementCampaign.find(_1.id).approve!(by: admin_user, digest: _1.current_digest) }
      end

      patch :update, params: { id: "new_feature", body: "<p>Other copy</p>" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(campaign.reload.body).to eq(draft_params[:body])
    end

    it "refuses copy edits after approval" do
      campaign.approve!(by: admin_user, digest: campaign.current_digest)

      patch :update, params: { id: "new_feature", body: "<p>Other copy</p>" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(campaign.reload.body).to eq(draft_params[:body])
    end

    it "refuses to send a draft" do
      post :deliver, params: { id: "new_feature" }

      expect(response).to have_http_status(:conflict)
      expect(SendFeatureAnnouncementCampaignJob.jobs.size).to eq(0)
    end

    it "cancels a campaign" do
      post :cancel, params: { id: "new_feature" }

      expect(json["campaign"]["state"]).to eq("cancelled")
    end

    it "shows delivery counts" do
      create(:feature_announcement_delivery, campaign: "new_feature", state: "skipped", reason: "not_in_audience")

      get :show, params: { id: "new_feature" }

      expect(json["deliveries"]).to eq([{ "state" => "skipped", "reason" => "not_in_audience", "count" => 1 }])
    end

    it "answers 404 for an unknown key" do
      get :show, params: { id: "missing" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
