# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::CategoriesController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @action = :index
    @params = {}
  end

  describe "GET 'index'" do
    before do
      Rails.cache.delete("taxonomies_for_nav")

      design = Taxonomy.find_or_create_by!(slug: "design")
      ui_and_web = Taxonomy.find_or_create_by!(slug: "ui-and-web", parent: design)
      @figma = Taxonomy.find_or_create_by!(slug: "figma", parent: ui_and_web)

      Rails.cache.delete("taxonomies_for_nav")
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "returns a stable flat list with labels and paths" do
        get @action, params: @params

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be true

        categories = body["categories"]
        expect(categories.map { |category| category["path"] }).to eq(categories.map { |category| category["path"] }.sort)

        figma = categories.find { |category| category["path"] == "design/ui-and-web/figma" }
        expect(figma).to eq(
          "id" => @figma.id,
          "name" => "figma",
          "label" => "Figma",
          "path" => "design/ui-and-web/figma",
          "parent_id" => @figma.parent_id
        )
      end

      it "allows clients to cache the category list for an hour without shared-cache reuse" do
        get @action, params: @params

        expect(response.headers["Cache-Control"]).to include("max-age=3600")
        expect(response.headers["Cache-Control"]).to include("private")
        expect(response.headers["Cache-Control"]).not_to include("public")
      end
    end

    it "grants access with the account scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      get @action, params: { access_token: token.token }
      expect(response).to be_successful
      expect(response.parsed_body["categories"]).to be_present
    end
  end
end
