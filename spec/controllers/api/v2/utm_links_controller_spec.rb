# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::UtmLinksController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @user)
  end

  def read_token
    create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
  end

  def write_token
    create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @params.merge!(access_token: read_token.token)
      end

      it "returns an empty list when there are no UTM links" do
        get @action, params: @params
        expect(response.parsed_body["utm_links"]).to eq([])
      end

      it "returns the seller's UTM links, newest first" do
        older = create(:utm_link, seller: @user, created_at: 2.days.ago)
        newer = create(:utm_link, seller: @user, created_at: 1.day.ago)

        get @action, params: @params
        expect(response.parsed_body["utm_links"].map { _1["id"] }).to eq([newer.external_id, older.external_id])
      end

      it "excludes deleted links but includes disabled ones" do
        create(:utm_link, seller: @user, title: "Dead", deleted_at: Time.current)
        create(:utm_link, seller: @user, title: "Disabled", disabled_at: Time.current)

        get @action, params: @params
        result = response.parsed_body["utm_links"]
        expect(result.map { _1["title"] }).to eq(["Disabled"])
        expect(result.first["enabled"]).to eq(false)
      end

      it "does not return another seller's links" do
        create(:utm_link, title: "Theirs")
        get @action, params: @params
        expect(response.parsed_body["utm_links"]).to eq([])
      end

      it "exposes external ids and the short URL, never internal identifiers" do
        link = create(:utm_link, seller: @user)

        get @action, params: @params
        result = response.parsed_body["utm_links"].first
        expect(result["id"]).to eq(link.external_id)
        expect(result["short_url"]).to eq(link.short_url)
        expect(result.keys).not_to include("seller_id", "ip_address", "browser_guid", "permalink")
      end
    end
  end

  describe "GET 'show'" do
    before do
      @utm_link = create(:utm_link, seller: @user)
      @action = :show
      @params = { id: @utm_link.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    it "returns the UTM link" do
      get @action, params: @params.merge(access_token: read_token.token)

      result = response.parsed_body
      expect(result["success"]).to eq(true)
      expect(result["utm_link"]["id"]).to eq(@utm_link.external_id)
      expect(result["utm_link"]["utm_url"]).to eq(@utm_link.utm_url)
    end

    it "returns an error for another seller's link" do
      other = create(:utm_link)
      get @action, params: { id: other.external_id, access_token: read_token.token }
      expect(response.parsed_body["success"]).to eq(false)
    end
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @params = {
        title: "Launch tweet",
        target_resource_type: "product_page",
        target_resource_id: @product.external_id,
        utm_source: "twitter",
        utm_medium: "social",
        utm_campaign: "launch"
      }
    end

    it "is refused with a read-only scope" do
      post @action, params: @params.merge(access_token: read_token.token)
      expect(response.code.to_i).to eq(403)
    end

    it "creates the link through the dashboard's own validation" do
      expect do
        post @action, params: @params.merge(access_token: write_token.token)
      end.to change { @user.utm_links.alive.count }.by(1)

      result = response.parsed_body
      expect(result["success"]).to eq(true)
      link = @user.utm_links.alive.last
      expect(link.title).to eq("Launch tweet")
      expect(link.target_resource).to eq(@product)
      expect(result["utm_link"]["id"]).to eq(link.external_id)
      expect(result["utm_link"]["target_resource_id"]).to eq(@product.external_id)
    end

    it "reports validation failures instead of raising" do
      post @action, params: @params.except(:utm_campaign).merge(access_token: write_token.token)

      result = response.parsed_body
      expect(result["success"]).to eq(false)
      expect(result["message"]).to include("Utm campaign can't be blank")
    end

    it "refuses a duplicate of an alive link with the same UTM fields and target" do
      post @action, params: @params.merge(access_token: write_token.token)
      expect(response.parsed_body["success"]).to eq(true)

      expect do
        post @action, params: @params.merge(access_token: write_token.token)
      end.not_to change { @user.utm_links.alive.count }
      expect(response.parsed_body["success"]).to eq(false)
    end
  end

  describe "PUT 'update'" do
    before do
      @utm_link = create(:utm_link, seller: @user)
      @action = :update
      @params = { id: @utm_link.external_id, title: "Renamed", utm_source: "newsletter" }
    end

    it "is refused with a read-only scope" do
      put @action, params: @params.merge(access_token: read_token.token)
      expect(response.code.to_i).to eq(403)
    end

    it "updates the campaign fields and keeps the permalink" do
      original_short_url = @utm_link.short_url

      put @action, params: @params.merge(access_token: write_token.token)

      expect(response.parsed_body["success"]).to eq(true)
      @utm_link.reload
      expect(@utm_link.title).to eq("Renamed")
      expect(@utm_link.utm_source).to eq("newsletter")
      expect(@utm_link.short_url).to eq(original_short_url)
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @utm_link = create(:utm_link, seller: @user)
      @action = :destroy
      @params = { id: @utm_link.external_id }
    end

    it "soft-deletes the link" do
      delete @action, params: @params.merge(access_token: write_token.token)

      expect(response.parsed_body["success"]).to eq(true)
      expect(@utm_link.reload.deleted?).to eq(true)
    end
  end

  describe "PUT 'disable' / 'enable'" do
    before do
      @utm_link = create(:utm_link, seller: @user)
    end

    it "disables and re-enables without deleting" do
      put :disable, params: { id: @utm_link.external_id, access_token: write_token.token }
      expect(response.parsed_body.dig("utm_link", "enabled")).to eq(false)
      expect(@utm_link.reload.active?).to eq(false)
      expect(@utm_link.alive?).to eq(true)

      put :enable, params: { id: @utm_link.external_id, access_token: write_token.token }
      expect(response.parsed_body.dig("utm_link", "enabled")).to eq(true)
      expect(@utm_link.reload.active?).to eq(true)
    end
  end
end
