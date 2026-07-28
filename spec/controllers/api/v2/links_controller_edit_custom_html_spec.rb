# frozen_string_literal: true

require "spec_helper"

describe Api::V2::LinksController do
  before do
    @user = create(:user)
    @other_user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @user)
    @other_product = create(:product, user: @other_user)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales edit_products")
    Feature.activate_user(:custom_html_pages, @user)
  end

  describe "GET 'custom_html'" do
    it "returns the published page HTML with has_landing_page and landing_url" do
      @product.update!(custom_html: "<section><h1>Landing</h1></section>")

      get :custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["custom_html"]).to include("<h1>Landing</h1>")
      expect(body["has_landing_page"]).to eq(true)
      expect(body["landing_url"]).to eq(@product.long_url)
    end

    it "returns has_landing_page false and nil custom_html when no page is published" do
      get :custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id }

      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["custom_html"]).to be_nil
      expect(body["has_landing_page"]).to eq(false)
    end

    it "does not reveal another seller's product page" do
      @other_product.update!(custom_html: "<section>Someone else's page</section>")

      get :custom_html, params: { format: :json, access_token: @token.token, id: @other_product.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ "success" => false, "message" => "The product was not found." })
    end

    it "rejects the read when the custom_html_pages feature is disabled" do
      Feature.deactivate_user(:custom_html_pages, @user)
      @product.update!(custom_html: "<section>Existing</section>")

      get :custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to eq("You do not have access to custom HTML pages.")
    end

    it "returns 401 without a token" do
      get :custom_html, params: { format: :json, id: @product.external_id }
      expect(response).to have_http_status(:unauthorized)
    end

    it "allows a read-scoped token without edit_products" do
      read_only = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
      @product.update!(custom_html: "<section>Readable</section>")

      get :custom_html, params: { format: :json, access_token: read_only.token, id: @product.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["custom_html"]).to include("Readable")
    end
  end

  describe "POST 'edit_custom_html'" do
    before do
      @product.update!(custom_html: %(<section><h1>Welcome</h1><a data-gumroad-action="buy">Buy now</a><p style="color: blue">Grab it</p></section>))
    end

    it "replaces exactly the matched snippet and leaves the rest of the page untouched" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: %(<p style="color: blue">Grab it</p>),
        replace: %(<p style="color: pink">Grab it</p>),
      }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      stored = @product.reload.custom_html
      expect(stored).to include(%(<p style="color: pink">Grab it</p>))
      expect(stored).to include("<h1>Welcome</h1>")
      expect(stored).not_to include("color: blue")
    end

    it "returns previous_custom_html and landing_url so the agent can recover and echo where the page lives" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: "<h1>Welcome</h1>", replace: "<h1>Hello</h1>",
      }

      body = response.parsed_body
      expect(body["previous_custom_html"]).to include("<h1>Welcome</h1>")
      expect(body["custom_html"]).to include("<h1>Hello</h1>")
      expect(body["landing_url"]).to eq(@product.long_url)
    end

    it "refuses when find does not appear in the current HTML, without writing" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: "<h1>Not on the page</h1>", replace: "<h1>Hello</h1>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/does not appear/i)
      expect(@product.reload.custom_html).to include("<h1>Welcome</h1>")
    end

    it "refuses an ambiguous find that matches more than once, naming the count" do
      @product.update!(custom_html: "<section><p>Buy now</p><p>Buy now</p></section>")

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: "<p>Buy now</p>", replace: "<p>Get it</p>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/matches 2 places/i)
      expect(@product.reload.custom_html).not_to include("Get it")
    end

    it "re-sanitizes the full edited page, stripping a disallowed script the edit introduces" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: "<h1>Welcome</h1>",
        replace: %(<h1>Welcome</h1><script src="https://evil.com/x.js"></script>),
      }

      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["sanitization_report"]["total_removed"]).to eq(1)
      expect(@product.reload.custom_html).not_to include("evil.com")
    end

    it "unpublishes the page when the edit sanitizes to nothing, matching the full update's blank-to-nil behavior" do
      @product.update!(custom_html: "<section><h1>Welcome</h1></section>")

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: "<section><h1>Welcome</h1></section>", replace: "",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(@product.reload.custom_html).to be_nil
      # The native product page (with its own buy button) is back, so no buy warning applies.
      expect(body).not_to have_key("warning")
    end

    it "warns when the edit removes the page's only buy element" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: %(<a data-gumroad-action="buy">Buy now</a>), replace: "",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["warning"]).to include("does not include a buy element")
      expect(@product.reload.custom_html).not_to include("data-gumroad-action")
    end

    it "does not warn when the edited page keeps its buy element" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: "<h1>Welcome</h1>", replace: "<h1>Hello</h1>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body).not_to have_key("warning")
    end

    it "refuses to edit when no custom HTML page exists" do
      @product.update!(custom_html: nil)

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: "<h1>Welcome</h1>", replace: "<h1>Hello</h1>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/no custom HTML page to edit/i)
    end

    it "rejects an edit that would push the page over the size limit, without writing" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @product.external_id,
        find: "<h1>Welcome</h1>",
        replace: "<h1>#{"a" * Page::MAX_CUSTOM_HTML_LENGTH}</h1>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/too long/i)
      expect(@product.reload.custom_html).to include("<h1>Welcome</h1>")
    end

    it "requires find to be a non-empty string" do
      post :edit_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, find: "", replace: "x" }
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/find is required/i)

      post :edit_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, replace: "x" }
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/find is required/i)
    end

    it "requires replace to be a string" do
      post :edit_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, find: "<h1>Welcome</h1>" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/replace is required/i)
    end

    it "does not edit another seller's product page" do
      @other_product.update!(custom_html: "<section><h1>Theirs</h1></section>")

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: @other_product.external_id,
        find: "<h1>Theirs</h1>", replace: "<h1>Mine now</h1>",
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ "success" => false, "message" => "The product was not found." })
      expect(@other_product.reload.custom_html).to include("<h1>Theirs</h1>")
    end

    it "returns 404 when the id only matches another seller's custom permalink" do
      @other_product.update!(custom_permalink: "another-sellers-page", custom_html: "<section><h1>Theirs</h1></section>")

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token, id: "another-sellers-page",
        find: "<h1>Theirs</h1>", replace: "<h1>Mine now</h1>",
      }

      expect(response.parsed_body).to eq({ "success" => false, "message" => "The product was not found." })
      expect(@other_product.reload.custom_html).to include("<h1>Theirs</h1>")
    end

    it "returns 401 without a token" do
      post :edit_custom_html, params: { format: :json, id: @product.external_id, find: "a", replace: "b" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a token without the edit_products scope" do
      read_only = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")

      post :edit_custom_html, params: { format: :json, access_token: read_only.token, id: @product.external_id, find: "<h1>Welcome</h1>", replace: "x" }

      expect(response).to have_http_status(:forbidden)
      expect(@product.reload.custom_html).to include("<h1>Welcome</h1>")
    end

    it "rejects the edit when the custom_html_pages feature is disabled" do
      Feature.deactivate_user(:custom_html_pages, @user)

      post :edit_custom_html, params: { format: :json, access_token: @token.token, id: @product.external_id, find: "<h1>Welcome</h1>", replace: "x" }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to eq("You do not have access to custom HTML pages.")
      expect(@product.reload.custom_html).to include("<h1>Welcome</h1>")
    end
  end
end
