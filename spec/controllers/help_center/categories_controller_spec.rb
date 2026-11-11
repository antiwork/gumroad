# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe HelpCenter::CategoriesController, inertia: true do
  render_views

  describe "GET show" do
    let(:category) { HelpCenter::Category.first }

    it "returns successful response with Inertia page data" do
      get :show, params: { slug: category.slug }
      expect(response).to be_successful
      expect(inertia.component).to eq("HelpCenter/Categories/Show")
      expect(inertia.props[:category]).to include(
        title: category.title,
        slug: category.slug
      )
      expect(inertia.props[:category][:articles]).to be_an(Array)
    end

    it "includes sidebar categories" do
      get :show, params: { slug: category.slug }
      expect(inertia.props[:sidebar_categories]).to be_an(Array)
      expect(inertia.props[:sidebar_categories].first).to include(:title, :slug, :url)
    end

    it "sets meta tags" do
      get :show, params: { slug: category.slug }
      expect(response.body).to include("#{category.title} - Gumroad Help Center</title>")
    end

    it "gives each category its own title, description and canonical" do
      heads = HelpCenter::Category.all.first(3).map do |cat|
        get :show, params: { slug: cat.slug }
        html = Nokogiri::HTML.parse(response.body)

        expect(html.at_css("title").text).to eq("#{cat.title} - Gumroad Help Center")
        expect(html.at_css("link[rel=canonical]")["href"]).to end_with("/help/category/#{cat.slug}")
        description = html.at_css("meta[name=description]")["content"]
        expect(description).to start_with("#{cat.title}: ")
        expect(description.length).to be <= 160
        expect(html.at_css("meta[property='og:description']")["content"]).to eq(description)
        expect(html.at_css("meta[property='og:url']")["content"]).to end_with("/help/category/#{cat.slug}")

        [html.at_css("title").text, description]
      end

      expect(heads.uniq.size).to eq(3)
    end

    it "serves the category's article links inside noscript so a crawler without JavaScript can reach them" do
      get :show, params: { slug: category.slug }

      noscripts = Nokogiri::HTML.parse(response.body).css("noscript")
      expect(noscripts.size).to eq(1)
      fallback = noscripts.first

      expect(fallback.at_css("h1").text).to eq(category.title)
      hrefs = fallback.css("a").map { |a| a["href"] }
      expect(category.articles).not_to be_empty
      expect(hrefs).to include(*category.articles.map { |article| "/help/article/#{article.slug}" })
      expect(hrefs).to include(*category.categories_for_same_audience.map { |sibling| "/help/category/#{sibling.slug}" })
    end

    it "redirects to help center root for non-existent categories" do
      get :show, params: { slug: "non-existent-category" }
      expect(response).to redirect_to(help_center_root_path)
    end

    context "with a legacy .html suffixed URL" do
      it "redirects permanently to the canonical category URL" do
        get :show, params: { slug: category.slug, format: "html" }
        expect(response).to have_http_status(:moved_permanently)
        expect(response).to redirect_to("/help/category/#{category.slug}")
      end
    end
  end
end
