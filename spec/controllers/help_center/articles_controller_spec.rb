# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe HelpCenter::ArticlesController, inertia: true do
  render_views

  describe "GET index" do
    it "returns successful response with Inertia page data" do
      get :index
      expect(response).to be_successful
      expect(inertia.component).to eq("HelpCenter/Articles/Index")
      expect(inertia.props[:categories]).to be_an(Array)
      expect(inertia.props[:categories]).not_to be_empty
      expect(inertia.props[:categories].first).to include(:title, :url, :audience, :articles)
    end

    it "includes all categories with their articles" do
      get :index
      categories = inertia.props[:categories]

      expect(categories.map { |c| c[:title] }).to include("Accessing your purchase", "Before you buy", "Open an account")

      category_with_articles = categories.find { |c| c[:articles].present? }
      expect(category_with_articles[:articles].first).to include(:title, :url)
    end

    it "sets meta tags" do
      get :index
      expect(response.body).to include("Gumroad Help Center</title>")
    end

    it "serves every category and article link inside noscript so a crawler without JavaScript can reach them" do
      get :index

      html = Nokogiri::HTML.parse(response.body)
      expect(html.at_css("title").text).to eq("Gumroad Help Center")

      noscripts = html.css("noscript")
      expect(noscripts.size).to eq(1)
      fallback = noscripts.first
      expect(fallback.at_css("h1").text).to eq("Gumroad Help Center")

      article_hrefs = fallback.css("a").map { |a| a["href"] }.select { |href| href.start_with?("/help/article/") }
      expect(article_hrefs).to match_array(HelpCenter::Article.all.map { |article| "/help/article/#{article.slug}" })
      expect(article_hrefs.size).to be > 50

      category_hrefs = fallback.css("h2 a").map { |a| a["href"] }
      expect(category_hrefs).to eq(HelpCenter::Category.all.map { |category| "/help/category/#{category.slug}" })
    end

    it "escapes titles so none can close the noscript element" do
      allow_any_instance_of(HelpCenter::Article).to receive(:title).and_return(%(x</NoScript><img src=x onerror="alert(1)">))

      get :index

      expect(response.body.scan(%r{</noscript}i).size).to eq(1)
      expect(response.body).not_to include("<img src=x")
    end
  end

  describe "GET show" do
    let(:article) { HelpCenter::Article.first }

    it "serves the article title and body inside noscript so a crawler without JavaScript sees the text" do
      get :show, params: { slug: article.slug }

      noscript = Nokogiri::HTML.parse(response.body).at_css("noscript")
      expect(noscript).to be_present
      expect(noscript.at_css("h1").text.strip).to eq(article.title)
      expect(noscript.text.squish.length).to be > 200
    end

    it "returns successful response with Inertia page data" do
      get :show, params: { slug: article.slug }
      expect(response).to be_successful
      expect(inertia.component).to eq("HelpCenter/Articles/Show")
      expect(inertia.props[:article]).to include(
        title: article.title,
        slug: article.slug
      )
      expect(inertia.props[:article][:category]).to include(:title, :slug, :url)
    end

    it "includes sidebar categories" do
      get :show, params: { slug: article.slug }
      expect(inertia.props[:sidebar_categories]).to be_an(Array)
      expect(inertia.props[:sidebar_categories].first).to include(:title, :slug, :url)
    end

    it "sets meta tags" do
      get :show, params: { slug: article.slug }
      expect(response.body).to include("#{CGI.escapeHTML(article.title)} - Gumroad Help Center</title>")
    end

    it "sets description meta tags from the article" do
      get :show, params: { slug: article.slug }
      html = Nokogiri::HTML.parse(response.body)
      expect(html.xpath("//meta[@name='description']/@content").text).to eq(article.description)
      expect(html.xpath("//meta[@property='og:description']/@content").text).to eq(article.description)
      expect(html.xpath("//meta[@name='twitter:description']/@content").text).to eq(article.description)
    end

    it "redirects to help center root for non-existent articles" do
      get :show, params: { slug: "non-existent-article" }
      expect(response).to redirect_to(help_center_root_path)
    end

    context "with a legacy .html suffixed URL" do
      it "redirects permanently to the canonical article URL" do
        get :show, params: { slug: article.slug, format: "html" }
        expect(response).to have_http_status(:moved_permanently)
        expect(response).to redirect_to("/help/article/#{article.slug}")
      end

      it "preserves the query string" do
        get :show, params: { slug: article.slug, format: "html", utm_source: "newsletter" }
        expect(response).to redirect_to("/help/article/#{article.slug}?utm_source=newsletter")
      end
    end

    context "with legacy article redirect" do
      it "redirects to the correct URL" do
        get :show, params: { slug: "284-jobs-at-gumroad" }
        expect(response).to redirect_to("/about#jobs")
        expect(response).to have_http_status(:moved_permanently)
      end
    end
  end
end
