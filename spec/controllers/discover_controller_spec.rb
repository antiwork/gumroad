# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe DiscoverController, type: :controller, inertia: true do
  render_views

  let(:discover_domain_with_protocol) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @buyer = create(:user)
    @product = create(:product, user: create(:user, name: "Gumstein"))
    sign_in @buyer
  end

  describe "#index" do
    it "displays navigation" do
      sign_in @buyer

      get :index

      expect(inertia).to render_component("Discover/Index")
    end

    it "renders the proper meta tags with no extra parameters" do
      get :index

      expect(response.body).to have_selector("title:contains('Gumroad')", visible: false)
      expect(response.body).to have_selector("meta[property='og:type'][content='website']", visible: false)
      expect(response.body).to have_selector("meta[property='og:description'][content='Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs.']", visible: false)
      expect(response.body).to have_selector("meta[name='description'][content='Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs.']", visible: false)
      expect(response.body).to have_selector("link[rel='canonical'][href='#{discover_domain_with_protocol}/']", visible: false)
    end

    it "renders the proper meta tags when a search query was submitted" do
      get :index, params: { query: "tests" }

      expect(response.body).to have_selector("title:contains('Gumroad')", visible: false)
      expect(response.body).to have_selector("meta[property='og:description'][content='Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs.']", visible: false)
      expect(response.body).to have_selector("meta[name='description'][content='Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs.']", visible: false)
      expect(response.body).to have_selector("link[rel='canonical'][href='#{discover_domain_with_protocol}/?query=tests']", visible: false)
    end

    it "renders the proper meta tags when a specific tag has been selected" do
      get :index, params: { tags: "3d models" }

      description = "Browse over 0 3D assets including 3D models, CG textures, HDRI environments & more" \
                    " for VFX, game development, AR/VR, architecture, and animation."
      expect(response.body).to have_selector("title:contains('Professional 3D Modeling Assets | Gumroad')", visible: false)
      expect(response.body).to have_selector("meta[property='og:description'][content='#{description}']", visible: false)
      expect(response.body).to have_selector("meta[name='description'][content='#{description}']", visible: false)
      expect(response.body).to have_selector("link[rel='canonical'][href='#{discover_domain_with_protocol}/?tags=3d+models']", visible: false)
    end

    it "renders the proper meta tags when a specific tag has been selected" do
      get :index, params: { tags: "3d      - mODELs" }

      description = "Browse over 0 3D assets including 3D models, CG textures, HDRI environments & more" \
                    " for VFX, game development, AR/VR, architecture, and animation."
      expect(response.body).to have_selector("title:contains('Professional 3D Modeling Assets | Gumroad')", visible: false)
      expect(response.body).to have_selector("meta[property='og:description'][content='#{description}']", visible: false)
      expect(response.body).to have_selector("meta[name='description'][content='#{description}']", visible: false)
      expect(response.body).to have_selector("link[rel='canonical'][href='#{discover_domain_with_protocol}/?tags=3d+models']", visible: false)
    end

    it "stores the search query" do
      cookies[:_gumroad_guid] = "custom_guid"

      root = Taxonomy.create!(slug: "3d")
      root.children.create!(slug: "3d-modeling")

      expect do
        get :index, params: { taxonomy: "3d/3d-modeling", query: "stl files" }
      end.to change(DiscoverSearch, :count).by(1).and change(DiscoverSearchSuggestion, :count).by(1)

      expect(DiscoverSearch.last!.attributes).to include(
        "query" => "stl files",
        "taxonomy_id" => Taxonomy.find_by_path(["3d", "3d-modeling"]).id,
        "user_id" => @buyer.id,
        "ip_address" => "0.0.0.0",
        "browser_guid" => "custom_guid",
        "autocomplete" => false
      )
      expect(DiscoverSearch.last!.discover_search_suggestion).to be_present
    end

    context "meta description total count" do
      let(:total_products) { 3 }

      before do
        total_products.times do |i|
          product = create(:product, :with_films_taxonomy, user: create(:recommendable_user))
          product.tag!("3d models")
        end
        Link.import(refresh: true, force: true)
      end

      it "renders the correct total search result size in the meta description" do
        get :index, params: { tags: "3d models" }

        expect(response.body).to match(
          /Browse over \d+ 3D assets including 3D models, CG textures, HDRI environments (?:&amp;|&) more for VFX, game development, AR\/VR, architecture, and animation\./
        )
      end
    end
  end
end
