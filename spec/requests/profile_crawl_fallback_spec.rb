# frozen_string_literal: true

require "spec_helper"

describe "profile page crawl fallback", :elasticsearch_wait_for_refresh, type: :request do
  let(:seller) { create(:named_user, name: "Fallback Creator", bio: "I make things.\n\nAnd write about them.") }

  def noscript_fallback
    Nokogiri::HTML.parse(response.body).at_css("noscript article")
  end

  def product_labels
    noscript_fallback.css("nav[aria-label='Products'] a").map { _1.text.strip }
  end

  def get_profile
    get "http://#{seller.subdomain}/"
  end

  context "when the profile is public" do
    let!(:product) { create(:product, user: seller, name: "Crawlable Product") }

    it "serves the creator name, bio and product links inside noscript" do
      get_profile

      expect(response).to have_http_status(:ok)

      fallback = noscript_fallback
      expect(fallback).to be_present
      expect(fallback.at_css("h1").text.strip).to eq("Fallback Creator")
      expect(fallback.text).to include("I make things.")
      expect(fallback.text).to include("And write about them.")
      expect(product_labels).to eq(["Crawlable Product"])
      expect(fallback.at_css("nav a")["href"]).to include(product.unique_permalink)
    end

    it "escapes the creator name, the bio and a product name" do
      seller.update!(name: "</noscript><script>alert(1)</script>", bio: "</NOSCRIPT><img src=x onerror=alert(1)>")
      product.update!(name: "</noscript><b>Bold</b>")

      get_profile

      expect(response.body.scan(%r{</noscript}i).size).to eq(1)
      expect(response.body).not_to include("<img src=x")
      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(noscript_fallback.at_css("h1").text).to eq("</noscript><script>alert(1)</script>")
      expect(noscript_fallback.at_css("h1 + p").text).to eq("</NOSCRIPT><img src=x onerror=alert(1)>")
      expect(product_labels).to eq(["</noscript><b>Bold</b>"])
    end

    it "keeps entity-encoded markup as the literal text the creator typed" do
      seller.update!(name: "&lt;/noscript&gt; Creator", bio: "&lt;/noscript&gt;&lt;b&gt;bio")
      product.update!(name: "&lt;/noscript&gt; Product")

      get_profile

      expect(response.body.scan(%r{</noscript}i).size).to eq(1)
      expect(noscript_fallback.at_css("h1").text).to eq("&lt;/noscript&gt; Creator")
      expect(noscript_fallback.at_css("h1 + p").text).to eq("&lt;/noscript&gt;&lt;b&gt;bio")
      expect(product_labels).to eq(["&lt;/noscript&gt; Product"])
    end

    it "keeps the bio as text rather than markup" do
      seller.update!(bio: "I make <b>things</b> & sell them")

      get_profile

      expect(noscript_fallback.at_css("h1 + p").text).to eq("I make <b>things</b> & sell them")
      expect(noscript_fallback.css("b")).to be_empty
    end

    it "leaves out a product the profile cannot show" do
      create(:product, user: seller, name: "Deleted Product", deleted_at: 1.hour.ago)
      create(:product, user: seller, name: "Archived Product", archived: true)
      create(:product, user: seller, name: "Unpublished Product", purchase_disabled_at: 1.hour.ago)

      get_profile

      expect(product_labels).to eq(["Crawlable Product"])
    end

    it "links exactly the products a saved products section shows" do
      create(:product, user: seller, name: "Other Product")
      section = create(:seller_profile_products_section, seller:, shown_products: [product.id])
      create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [section.id] }] })

      get_profile

      expect(product_labels).to eq(["Crawlable Product"])
    end

    it "links a featured product once, not once per section it appears in" do
      featured = create(:seller_profile_featured_product_section, seller:, featured_product_id: product.id)
      section = create(:seller_profile_products_section, seller:, shown_products: [product.id])
      create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [featured.id, section.id] }] })

      get_profile

      expect(product_labels).to eq(["Crawlable Product"])
    end

    it "leaves out a saved section that no tab shows" do
      other = create(:product, user: seller, name: "Unshown Product")
      shown = create(:seller_profile_products_section, seller:, shown_products: [product.id])
      create(:seller_profile_products_section, seller:, shown_products: [other.id])
      create(:seller_profile, seller:, json_data: { tabs: [{ name: "", sections: [shown.id] }] })

      get_profile

      expect(response).to have_http_status(:ok)
      expect(product_labels).to eq(["Crawlable Product"])
    end

    it "links every tab's products in tab order" do
      second = create(:product, user: seller, name: "Second Tab Product")
      later_tab = create(:seller_profile_products_section, seller:, shown_products: [product.id])
      first_tab = create(:seller_profile_products_section, seller:, shown_products: [second.id])
      create(:seller_profile, seller:, json_data: { tabs: [{ name: "First", sections: [first_tab.id] }, { name: "Second", sections: [later_tab.id] }] })

      get_profile

      expect(product_labels).to eq(["Second Tab Product", "Crawlable Product"])
    end

    it "serves the fallback on the seller's custom domain, linking the products there" do
      create(:custom_domain, user: seller, domain: "fallback-creator.example.com")

      get "http://fallback-creator.example.com/"

      expect(response).to have_http_status(:ok)
      expect(noscript_fallback.at_css("h1").text).to eq("Fallback Creator")
      expect(product_labels).to eq(["Crawlable Product"])
      expect(URI(noscript_fallback.at_css("nav a")["href"]).host).to eq("fallback-creator.example.com")
    end

    it "is not built for an Inertia visit" do
      get "http://#{seller.subdomain}/", headers: { "X-Inertia" => "true" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["component"]).to eq("Users/Show")
      expect(response.body).not_to include("<noscript")
    end

    it "is not served on the JSON profile or the redirect to the subdomain" do
      get "http://#{DOMAIN}/#{seller.username}.json"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to be_a(Hash)
      expect(response.body).not_to include("<noscript")

      get "http://#{DOMAIN}/#{seller.username}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.body).not_to include("<noscript")
    end

    it "is not served on a custom HTML profile" do
      seller.update!(custom_html: "<main><h1>Custom profile</h1></main>")
      Feature.activate_user(:custom_html_pages, seller)

      get_profile

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML.parse(response.body).at_css("noscript article")).to be_nil
      expect(response.body).not_to include("Crawlable Product")
    end

    it "serves the name and bio with no product list when the creator has nothing for sale" do
      product.destroy!

      get_profile

      expect(noscript_fallback.at_css("h1").text.strip).to eq("Fallback Creator")
      expect(noscript_fallback.text).to include("I make things.")
      expect(noscript_fallback.css("nav")).to be_empty
    end
  end

  context "when the profile has no bio" do
    let!(:product) { create(:product, user: seller, name: "Crawlable Product") }

    it "serves no empty paragraph" do
      seller.update!(bio: nil)

      get_profile

      expect(noscript_fallback.css("h1 + p")).to be_empty
      expect(noscript_fallback.text).to include("Crawlable Product")
    end
  end
end
