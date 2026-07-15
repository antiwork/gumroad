# frozen_string_literal: true

require "spec_helper"

describe Api::V2::UsersController do
  before do
    @user = create(:user, name: "Jane Doe", bio: "Maker of things")
    @app = create(:oauth_application, owner: create(:user))
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile edit_profile")
    Feature.activate_user(:custom_html_pages, @user)
  end

  describe "GET 'custom_html'" do
    it "returns the published custom HTML and the landing-page flag" do
      @user.update!(custom_html: "<section>Published HTML</section>")

      get :custom_html, params: { format: :json, access_token: @token.token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["custom_html"]).to eq("<section>Published HTML</section>")
      expect(body["has_landing_page"]).to eq(true)
      expect(body["profile_url"]).to eq(@user.profile_url)
    end

    it "returns the published custom HTML verbatim as the pull render" do
      @user.update!(custom_html: "<section>Published HTML</section>")

      get :custom_html, params: { format: :json, access_token: @token.token }

      expect(response.parsed_body["rendered_html"]).to eq("<section>Published HTML</section>")
    end

    it "returns a default storefront render as the pull starting point when no custom HTML is published" do
      product = create(:product, user: @user, name: "Design Course")

      get :custom_html, params: { format: :json, access_token: @token.token }

      body = response.parsed_body
      expect(body["custom_html"]).to be_nil
      expect(body["rendered_html"]).to include("<!doctype html>")
      expect(body["rendered_html"]).to include("<h1>Jane Doe</h1>")
      expect(body["rendered_html"]).to include("Design Course")
      expect(body["rendered_html"]).to include(product.long_url)
    end

    it "reports no landing page when none is published" do
      get :custom_html, params: { format: :json, access_token: @token.token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["custom_html"]).to be_nil
      expect(body["has_landing_page"]).to eq(false)
    end

    it "returns 401 without a token" do
      get :custom_html, params: { format: :json }
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a token without a read scope" do
      write_only = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_profile")

      get :custom_html, params: { format: :json, access_token: write_only.token }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PUT 'update_custom_html'" do
    it "sanitizes custom HTML before storing while allowing inline JavaScript" do
      html = <<~HTML
        <section onclick="openModal()">
          <script>window.ready = true;</script>
          <script src="https://evil.com/x.js"></script>
          <a href="javascript:alert(1)">Click</a>
        </section>
      HTML

      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: html }

      expect(response).to have_http_status(:ok)
      stored_html = @user.reload.custom_html
      expect(stored_html).to include(%(onclick="openModal()"))
      expect(stored_html).to include("<script>window.ready = true;</script>")
      expect(stored_html).not_to include("evil.com")
      expect(stored_html).not_to include("javascript:")
    end

    it "clears custom HTML when passed nil" do
      @user.update!(custom_html: "<section>Published HTML</section>")

      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: nil }

      expect(response).to have_http_status(:ok)
      expect(@user.reload.custom_html).to be_nil
    end

    it "returns previous_custom_html so the agent has one-shot recovery from an overwrite" do
      @user.update!(custom_html: "<section>Old HTML</section>")

      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: "<section>New HTML</section>" }

      body = response.parsed_body
      expect(body["custom_html"]).to eq("<section>New HTML</section>")
      expect(body["previous_custom_html"]).to eq("<section>Old HTML</section>")
      expect(body["profile_url"]).to eq(@user.profile_url)
    end

    it "returns previous_custom_html as null on the first push (nothing to recover)" do
      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: "<section>First HTML</section>" }

      body = response.parsed_body
      expect(body).to have_key("previous_custom_html")
      expect(body["previous_custom_html"]).to be_nil
    end

    it "returns a sanitization_report listing what was stripped" do
      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: %(<section><script src="https://evil.com/x.js"></script><h1>Keep</h1></section>) }

      report = response.parsed_body["sanitization_report"]
      expect(report["total_removed"]).to eq(1)
      expect(report["removed_tags"].first["reason"]).to eq("script src host not allowed")
    end

    it "does not return a buy-affordance warning — a profile has no native checkout" do
      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: "<section><h1>Landing page</h1></section>" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("warning")
    end

    it "rejects HTML over the size limit before the sanitizer parses it" do
      oversized = "<section>#{"a" * Page::MAX_CUSTOM_HTML_LENGTH}</section>"

      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: oversized }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/too long/i)
      expect(@user.reload.custom_html).to be_nil
    end

    it "rejects a non-string custom_html with a controlled error, not a 500" do
      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: ["<section>HTML</section>"] }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/must be a string/i)
    end

    it "requires the custom_html parameter" do
      put :update_custom_html, params: { format: :json, access_token: @token.token }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/required/i)
    end

    it "refuses to publish until the account email is confirmed" do
      unconfirmed = create(:user, confirmed_at: nil)
      Feature.activate_user(:custom_html_pages, unconfirmed)
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: unconfirmed.id, scopes: "edit_profile")

      put :update_custom_html, params: { format: :json, access_token: token.token, custom_html: "<section>HTML</section>" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/confirm your email/i)
      expect(unconfirmed.reload.custom_html).to be_nil
    end

    it "returns 401 without a token" do
      put :update_custom_html, params: { format: :json, custom_html: "<section>HTML</section>" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a token without the edit_profile scope" do
      read_only = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile")

      put :update_custom_html, params: { format: :json, access_token: read_only.token, custom_html: "<section>HTML</section>" }

      expect(response).to have_http_status(:forbidden)
      expect(@user.reload.custom_html).to be_nil
    end
  end

  describe "POST 'preview_custom_html'" do
    it "returns the sanitized HTML without writing to the profile" do
      input = %(<section><script src="https://evil.com/x.js"></script><h1>Keep</h1></section>)

      post :preview_custom_html, params: { format: :json, access_token: @token.token, custom_html: input }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["custom_html"]).to include("<h1>Keep</h1>")
      expect(body["custom_html"]).not_to include("evil.com")
      expect(@user.reload.custom_html).to be_nil
    end

    it "returns a sanitization_report alongside the sanitized HTML" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, custom_html: %(<section><script src="https://evil.com/x.js"></script><h1>Keep</h1></section>) }

      report = response.parsed_body["sanitization_report"]
      expect(report["total_removed"]).to eq(1)
      expect(report["removed_tags"].first["reason"]).to eq("script src host not allowed")
    end

    it "returns success with nil custom_html when input is blank" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, custom_html: "" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["custom_html"]).to be_nil
    end

    it "agrees with the PUT on input that sanitizes to empty" do
      input = "<script src=\"https://evil.com/x.js\"></script>"

      post :preview_custom_html, params: { format: :json, access_token: @token.token, custom_html: input }
      preview_html = response.parsed_body["custom_html"]

      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: input }
      stored_html = @user.reload.custom_html

      expect(preview_html).to eq(stored_html)
    end

    it "rejects oversized input before the sanitizer parses it" do
      oversized = "<section>#{"a" * Page::MAX_CUSTOM_HTML_LENGTH}</section>"

      post :preview_custom_html, params: { format: :json, access_token: @token.token, custom_html: oversized }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/too long/i)
    end

    it "requires the custom_html parameter" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/required/i)
    end

    it "returns 401 without a token" do
      post :preview_custom_html, params: { format: :json, custom_html: "<section>HTML</section>" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "when the custom_html_pages feature is disabled" do
    before { Feature.deactivate_user(:custom_html_pages, @user) }

    it "rejects GET custom_html with an access error" do
      get :custom_html, params: { format: :json, access_token: @token.token }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("You do not have access to custom HTML pages.")
    end

    it "rejects a custom_html update with an access error and leaves the page unchanged" do
      put :update_custom_html, params: { format: :json, access_token: @token.token, custom_html: "<section>New HTML</section>" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("You do not have access to custom HTML pages.")
      expect(@user.reload.custom_html).to be_nil
    end

    it "rejects preview_custom_html with an access error" do
      post :preview_custom_html, params: { format: :json, access_token: @token.token, custom_html: "<section>HTML</section>" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("You do not have access to custom HTML pages.")
    end
  end
end
