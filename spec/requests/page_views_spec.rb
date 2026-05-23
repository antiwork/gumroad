# frozen_string_literal: true

require "spec_helper"

describe PageViewsController, type: :request do
  let(:seller) { create(:user, username: "creator#{SecureRandom.hex(4)}") }
  let(:page) { create(:page, user: seller, html_content: "<section>Live page</section>") }
  let(:version) { create(:page_version, page: page, html: page.html_content) }

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    version
    page.publish!
  end

  describe "GET /:username/pages/:slug" do
    let(:inertia_headers) { { "X-Inertia" => "true" } }

    it "renders the public page for an alive seller with a published page" do
      get "/#{seller.username}/pages/#{page.slug}", headers: inertia_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["component"]).to eq("Pages/Show")
      props = body["props"]
      expect(props["page"]["slug"]).to eq(page.slug)
      expect(props["page"]["title"]).to eq(page.title)
      expect(props["page"]["html_content"]).to include("Live page")
      expect(props["page"]["seller"]["username"]).to eq(seller.username)
    end

    it "ships the published_version html in the iframe payload" do
      version.update!(html: "<section>Pinned version html</section>")
      page.update!(html_content: "<section>Editor draft</section>")
      page.publish!(version: version)

      get "/#{seller.username}/pages/#{page.slug}", headers: inertia_headers
      props = JSON.parse(response.body)["props"]
      expect(props["page"]["html_content"]).to include("Pinned version html")
      expect(props["page"]["html_content"]).not_to include("Editor draft")
    end

    it "returns 404 when the seller is suspended" do
      admin_user = create(:admin_user)
      seller.flag_for_fraud!(author_id: admin_user.id)
      seller.suspend_for_fraud!(author_id: admin_user.id)

      get "/#{seller.username}/pages/#{page.slug}", headers: inertia_headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when the page is not published" do
      page.unpublish!
      get "/#{seller.username}/pages/#{page.slug}", headers: inertia_headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when the page is soft-deleted" do
      page.mark_deleted!
      get "/#{seller.username}/pages/#{page.slug}", headers: inertia_headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for unknown sellers" do
      get "/nobody-here/pages/#{page.slug}", headers: inertia_headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 (not a draft leak) when the row is published with no pinned version" do
      # Simulate the corrupt state publish! now refuses to create. We bypass
      # publish! to force published=true with published_version_id=nil and
      # confirm the controller refuses to serve the html_content draft.
      page.update_columns(published: true, published_version_id: nil)
      get "/#{seller.username}/pages/#{page.slug}", headers: inertia_headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
