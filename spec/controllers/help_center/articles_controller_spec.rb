# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe HelpCenter::ArticlesController, inertia: true do
  describe "GET index" do
    it "returns http success and renders Inertia component" do
      get :index

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq("HelpCenter/Index")
      expect(inertia.props[:categories]).to be_present
    end
  end

  describe "GET show" do
    let(:article) { HelpCenter::Article.find(43) }

    it "returns http success and renders Inertia component with article props" do
      get :show, params: { slug: article.slug }

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq("HelpCenter/Article")
      expect(inertia.props[:article][:title]).to eq(article.title)
      expect(inertia.props[:article][:slug]).to eq(article.slug)
      expect(inertia.props[:article]).to have_key(:content_html)
    end

    it "includes categories for the same audience" do
      get :show, params: { slug: article.slug }

      expect(inertia.props[:categories]).to be_present
      category_titles = inertia.props[:categories].map { |c| c[:title] }
      article.category.categories_for_same_audience.each do |c|
        expect(category_titles).to include(c.title)
      end
    end

    HelpCenter::Article.all.each do |article|
      it "renders the article #{article.slug}" do
        get :show, params: { slug: article.slug }

        expect(response).to have_http_status(:ok)
        expect(inertia.props[:article][:title]).to eq(article.title)
      end
    end

    context "when article is not found" do
      it "redirects to the help center root path" do
        get :show, params: { slug: "nonexistent-slug" }

        expect(response).to redirect_to(help_center_root_path)
        expect(response).to have_http_status(:found)
      end
    end

    context "when accessing the old jobs article URL" do
      it "redirects to the about page jobs section with 301 status" do
        get :show, params: { slug: "284-jobs-at-gumroad" }

        expect(response).to redirect_to("/about#jobs")
        expect(response).to have_http_status(:moved_permanently)
      end
    end
  end
end
