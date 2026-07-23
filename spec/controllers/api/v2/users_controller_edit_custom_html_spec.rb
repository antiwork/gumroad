# frozen_string_literal: true

require "spec_helper"

describe Api::V2::UsersController do
  before do
    @user = create(:user, name: "Jane Doe", bio: "Maker of things")
    @app = create(:oauth_application, owner: create(:user))
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile edit_profile")
    Feature.activate_user(:custom_html_pages, @user)
  end

  describe "POST 'edit_custom_html'" do
    before do
      @user.update!(custom_html: %(<section><h1>Welcome</h1><p style="color: blue">Shop my art</p></section>))
    end

    it "replaces exactly the matched snippet and leaves the rest of the page untouched" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: %(<p style="color: blue">Shop my art</p>),
        replace: %(<p style="color: pink">Shop my art</p>),
      }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      stored = @user.reload.custom_html
      expect(stored).to include(%(<p style="color: pink">Shop my art</p>))
      expect(stored).to include("<h1>Welcome</h1>")
      expect(stored).not_to include("color: blue")
    end

    it "returns previous_custom_html so the agent has one-shot recovery from a bad edit" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<h1>Welcome</h1>", replace: "<h1>Hello</h1>",
      }

      body = response.parsed_body
      expect(body["previous_custom_html"]).to include("<h1>Welcome</h1>")
      expect(body["custom_html"]).to include("<h1>Hello</h1>")
      expect(body["profile_url"]).to eq(@user.profile_url)
    end

    it "deletes the snippet when replace is an empty string" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<h1>Welcome</h1>", replace: "",
      }

      expect(response.parsed_body["success"]).to eq(true)
      stored = @user.reload.custom_html
      expect(stored).not_to include("<h1>Welcome</h1>")
      expect(stored).to include("Shop my art")
    end

    it "refuses when find does not appear in the current HTML, without writing" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<h1>Not on the page</h1>", replace: "<h1>Hello</h1>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/does not appear/i)
      expect(@user.reload.custom_html).to include("<h1>Welcome</h1>")
    end

    it "refuses an ambiguous find that matches more than once, naming the count" do
      @user.update!(custom_html: "<section><p>Buy now</p><p>Buy now</p></section>")

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<p>Buy now</p>", replace: "<p>Get it</p>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/matches 2 places/i)
      # The page is unchanged (the sanitizer may normalize whitespace on save, so compare content).
      expect(@user.reload.custom_html.scan("<p>Buy now</p>").size).to eq(2)
      expect(@user.custom_html).not_to include("Get it")
    end

    it "treats find literally, not as a regex" do
      @user.update!(custom_html: "<section><p>Price: $10 (sale)</p></section>")

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "$10 (sale)", replace: "$8 (sale)",
      }

      expect(response.parsed_body["success"]).to eq(true)
      expect(@user.reload.custom_html).to include("$8 (sale)")
    end

    it "applies an edit whose find uses a plain space where the page has a non-breaking space" do
      # Agents reading the page routinely normalize U+00A0 to a plain space when echoing a
      # snippet back; exact-only matching made such an edit permanently unappliable and left the
      # proposal's Confirm button disabled forever (gumroad-private#1251). The stored page below
      # reflects what the sanitizer persists (it inserts newlines after some closing tags) — the
      # snippet matches it exactly except for the NBSP inside the span.
      @user.update!(custom_html: "<section><h1>Welcome<span>\u00A0</span></h1><p>Shop my art</p></section>")
      stored_before = @user.reload.custom_html
      expect(stored_before).to include("\u00A0")

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: stored_before.tr("\u00A0", " "), replace: "<h1>Hello</h1>",
      }

      expect(response.parsed_body["success"]).to eq(true)
      expect(@user.reload.custom_html).to include("<h1>Hello</h1>")
    end

    it "inserts the replacement literally even when it contains backslash sequences" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<h1>Welcome</h1>", replace: '<h1>Path \\0 and \\\\ stay</h1>',
      }

      expect(response.parsed_body["success"]).to eq(true)
      expect(@user.reload.custom_html).to include('Path \\0 and \\\\ stay')
    end

    it "re-sanitizes the full edited page, stripping a disallowed script the edit introduces" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<h1>Welcome</h1>",
        replace: %(<h1>Welcome</h1><script src="https://evil.com/x.js"></script>),
      }

      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["sanitization_report"]["total_removed"]).to eq(1)
      expect(@user.reload.custom_html).not_to include("evil.com")
    end

    it "unpublishes the page when the edit sanitizes to nothing, matching the full update's blank-to-nil behavior" do
      @user.update!(custom_html: "<section><h1>Welcome</h1></section>")

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<section><h1>Welcome</h1></section>", replace: "",
      }

      expect(response.parsed_body["success"]).to eq(true)
      expect(@user.reload.custom_html).to be_nil
    end

    it "refuses to edit when no custom HTML page exists" do
      @user.update!(custom_html: nil)

      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<h1>Welcome</h1>", replace: "<h1>Hello</h1>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/no custom HTML page to edit/i)
    end

    it "rejects an edit that would push the page over the size limit, without writing" do
      post :edit_custom_html, params: {
        format: :json, access_token: @token.token,
        find: "<h1>Welcome</h1>",
        replace: "<h1>#{"a" * Page::MAX_CUSTOM_HTML_LENGTH}</h1>",
      }

      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/too long/i)
      expect(@user.reload.custom_html).to include("<h1>Welcome</h1>")
    end

    it "requires find to be a non-empty string" do
      post :edit_custom_html, params: { format: :json, access_token: @token.token, find: "", replace: "x" }
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/find is required/i)

      post :edit_custom_html, params: { format: :json, access_token: @token.token, replace: "x" }
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/find is required/i)
    end

    it "requires replace to be a string" do
      post :edit_custom_html, params: { format: :json, access_token: @token.token, find: "<h1>Welcome</h1>" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/replace is required/i)
    end

    it "refuses until the account email is confirmed" do
      unconfirmed = create(:user, confirmed_at: nil)
      Feature.activate_user(:custom_html_pages, unconfirmed)
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: unconfirmed.id, scopes: "edit_profile")

      post :edit_custom_html, params: { format: :json, access_token: token.token, find: "a", replace: "b" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to match(/confirm your email/i)
    end

    it "returns 401 without a token" do
      post :edit_custom_html, params: { format: :json, find: "a", replace: "b" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a token without the edit_profile scope" do
      read_only = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile")

      post :edit_custom_html, params: { format: :json, access_token: read_only.token, find: "<h1>Welcome</h1>", replace: "x" }

      expect(response).to have_http_status(:forbidden)
      expect(@user.reload.custom_html).to include("<h1>Welcome</h1>")
    end

    it "rejects the edit when the custom_html_pages feature is disabled" do
      Feature.deactivate_user(:custom_html_pages, @user)

      post :edit_custom_html, params: { format: :json, access_token: @token.token, find: "<h1>Welcome</h1>", replace: "x" }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("You do not have access to custom HTML pages.")
      expect(@user.reload.custom_html).to include("<h1>Welcome</h1>")
    end
  end
end
