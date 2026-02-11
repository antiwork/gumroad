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
  end

  describe "GET show" do
    let(:article) { HelpCenter::Article.first }

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

    it "redirects to help center root for non-existent articles" do
      get :show, params: { slug: "non-existent-article" }
      expect(response).to redirect_to(help_center_root_path)
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
