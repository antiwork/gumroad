# frozen_string_literal: true

require "spec_helper"

describe Api::V2::PagesController do
  before do
    @user = create(:user, name: "Jane Doe")
    @app = create(:oauth_application, owner: create(:user))
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile edit_profile")
  end

  describe "GET 'index'" do
    it "returns the seller's slugged pages" do
      create(:user_page, pageable: @user, slug: "about", title: "About")
      create(:user_page, slug: "other", title: "Someone else's")

      get :index, params: { format: :json, access_token: @token.token }

      expect(response).to have_http_status(:ok)
      pages = response.parsed_body["pages"]
      expect(pages.map { _1["slug"] }).to eq(["about"])
      expect(pages.first["url"]).to eq("#{@user.subdomain_with_protocol}/about")
    end

    it "returns 401 without a token" do
      get :index, params: { format: :json }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET 'show'" do
    it "returns the page by slug" do
      create(:user_page, pageable: @user, slug: "faq", title: "FAQ", content: "<p>Q & A</p>")

      get :show, params: { format: :json, access_token: @token.token, id: "faq" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["page"]["title"]).to eq("FAQ")
      expect(response.parsed_body["page"]["content"]).to eq("<p>Q &amp; A</p>")
      expect(response.parsed_body["rendered_html"]).to include("<h1 class=\"page-title\">FAQ</h1>")
      expect(response.parsed_body["rendered_html"]).to include("<p>Q &amp; A</p>")
    end

    it "returns the stored HTML as the render for a custom HTML page" do
      create(:user_page, pageable: @user, slug: "studio", title: "Studio", content: nil, custom_html: "<h1>Studio</h1>")

      get :show, params: { format: :json, access_token: @token.token, id: "studio" }

      expect(response.parsed_body["rendered_html"]).to include("<h1>Studio</h1>")
      expect(response.parsed_body["rendered_html"]).not_to include("page-title")
    end

    it "reports a missing page" do
      get :show, params: { format: :json, access_token: @token.token, id: "nope" }

      expect(response.parsed_body["success"]).to eq(false)
    end
  end

  describe "POST 'create'" do
    it "creates a rich text page with a slug derived from the title" do
      post :create, params: { format: :json, access_token: @token.token, title: "My FAQ", content: "<p>Hi</p>" }

      expect(response).to have_http_status(:ok)
      page = @user.pages.last
      expect(page.slug).to eq("my-faq")
      expect(page.content).to eq("<p>Hi</p>")
    end

    it "honors an explicit slug" do
      post :create, params: { format: :json, access_token: @token.token, title: "FAQ", slug: "questions" }

      expect(@user.pages.last.slug).to eq("questions")
    end

    it "rejects an invalid explicit slug" do
      post :create, params: { format: :json, access_token: @token.token, title: "FAQ", slug: "Bad Slug!" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(@user.pages.count).to eq(0)
    end

    it "requires a title" do
      post :create, params: { format: :json, access_token: @token.token, content: "<p>Hi</p>" }

      expect(response.parsed_body["success"]).to eq(false)
    end

    it "requires the write scope" do
      read_only = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile")

      post :create, params: { format: :json, access_token: read_only.token, title: "FAQ" }

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a broad account-scope token without edit_profile" do
      # The v2 base controller accepts the legacy `account` scope as a fallback for
      # doorkeeper_authorize!; page writes must still demand edit_profile itself.
      broad = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")

      post :create, params: { format: :json, access_token: broad.token, title: "FAQ", content: "<p>Hi</p>" }

      expect(response).to have_http_status(:forbidden)
      expect(@user.pages.count).to eq(0)
    end

    it "creates a custom HTML page when the feature is enabled" do
      Feature.activate_user(:custom_html_pages, @user)

      post :create, params: { format: :json, access_token: @token.token, title: "Studio", custom_html: "<h1>Studio</h1>" }

      page = @user.pages.last
      expect(page.custom_html).to include("<h1>Studio</h1>")
      expect(page.content).to be_nil
    end

    it "refuses custom HTML without the feature" do
      post :create, params: { format: :json, access_token: @token.token, title: "Studio", custom_html: "<h1>Studio</h1>" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(@user.pages.count).to eq(0)
    end

    it "refuses both content and custom_html at once" do
      post :create, params: { format: :json, access_token: @token.token, title: "X", content: "<p>a</p>", custom_html: "<p>b</p>" }

      expect(response.parsed_body["success"]).to eq(false)
    end
  end

  describe "PUT 'update'" do
    let!(:page) { create(:user_page, pageable: @user, slug: "about", title: "About", content: "<p>Old</p>") }

    it "updates title and content" do
      put :update, params: { format: :json, access_token: @token.token, id: "about", title: "About me", content: "<p>New</p>" }

      expect(page.reload.title).to eq("About me")
      expect(page.content).to eq("<p>New</p>")
    end

    it "switches a rich text page to custom HTML, clearing content" do
      Feature.activate_user(:custom_html_pages, @user)

      put :update, params: { format: :json, access_token: @token.token, id: "about", custom_html: "<h1>Takeover</h1>" }

      expect(page.reload.custom_html).to include("<h1>Takeover</h1>")
      expect(page.content).to be_nil
    end

    it "clears custom_html when switching back to rich text, even with empty content" do
      Feature.activate_user(:custom_html_pages, @user)
      page.update!(content: nil, custom_html: "<h1>Takeover</h1>")

      put :update, params: { format: :json, access_token: @token.token, id: "about", content: "" }

      expect(page.reload.custom_html).to be_nil
      expect(page.content).to be_nil
    end

    it "cannot touch another seller's page" do
      create(:user_page, slug: "theirs", title: "Not yours")

      put :update, params: { format: :json, access_token: @token.token, id: "theirs", title: "Hijack" }

      expect(response.parsed_body["success"]).to eq(false)
    end
  end

  describe "DELETE 'destroy'" do
    it "deletes the page" do
      create(:user_page, pageable: @user, slug: "about", title: "About")

      expect do
        delete :destroy, params: { format: :json, access_token: @token.token, id: "about" }
      end.to change { @user.pages.count }.by(-1)
    end
  end
end
