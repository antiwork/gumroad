# frozen_string_literal: true

require "test_helper"

class HelpCenterArticlesControllerTest < ActionController::TestCase
  self.described_class = HelpCenter::ArticlesController
  tests HelpCenter::ArticlesController



  context_ HelpCenter::ArticlesController, inertia: true do
    render_views

  context_ "GET index" do
  test "returns successful response with Inertia page data" do
        get :index
        expect(response).to be_successful
        expect(inertia.component).to eq("HelpCenter/Articles/Index")
        expect(inertia.props[:categories]).to be_an(Array)
        expect(inertia.props[:categories]).not_to be_empty
        expect(inertia.props[:categories].first).to include(:title, :url, :audience, :articles)
      end

  test "includes all categories with their articles" do
        get :index
        categories = inertia.props[:categories]

        expect(categories.map { |c| c[:title] }).to include("Accessing your purchase", "Before you buy", "Open an account")

        category_with_articles = categories.find { |c| c[:articles].present? }
        expect(category_with_articles[:articles].first).to include(:title, :url)
      end

  test "sets meta tags" do
        get :index
        expect(response.body).to include("Gumroad Help Center</title>")
      end
    end

  context_ "GET show" do
      let(:article) { HelpCenter::Article.first }

  test "returns successful response with Inertia page data" do
        get :show, params: { slug: article.slug }
        expect(response).to be_successful
        expect(inertia.component).to eq("HelpCenter/Articles/Show")
        expect(inertia.props[:article]).to include(
          title: article.title,
          slug: article.slug
        )
        expect(inertia.props[:article][:category]).to include(:title, :slug, :url)
      end

  test "includes sidebar categories" do
        get :show, params: { slug: article.slug }
        expect(inertia.props[:sidebar_categories]).to be_an(Array)
        expect(inertia.props[:sidebar_categories].first).to include(:title, :slug, :url)
      end

  test "sets meta tags" do
        get :show, params: { slug: article.slug }
        expect(response.body).to include("#{CGI.escapeHTML(article.title)} - Gumroad Help Center</title>")
      end

  test "sets description meta tags from the article" do
        get :show, params: { slug: article.slug }
        html = Nokogiri::HTML.parse(response.body)
        expect(html.xpath("//meta[@name='description']/@content").text).to eq(article.description)
        expect(html.xpath("//meta[@property='og:description']/@value").text).to eq(article.description)
        expect(html.xpath("//meta[@name='twitter:description']/@content").text).to eq(article.description)
      end

  test "redirects to help center root for non-existent articles" do
        get :show, params: { slug: "non-existent-article" }
        expect(response).to redirect_to(help_center_root_path)
      end

  context_ "with legacy article redirect" do
  test "redirects to the correct URL" do
          get :show, params: { slug: "284-jobs-at-gumroad" }
          expect(response).to redirect_to("/about#jobs")
          expect(response).to have_http_status(:moved_permanently)
        end
      end
    end
  end
end
