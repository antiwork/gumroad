# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe HelpCenter::ArticlesController, type: :controller, inertia: true do
  render_views

  describe "GET index" do
    it "renders the Inertia page with categories" do
      get :index

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq("HelpCenter/Index")
      expect(inertia.props[:categories]).to be_present
      expect(inertia.props[:categories]).to be_an(Array)
      expect(inertia.props[:categories].first).to include(:title, :url, :audience, :articles)
    end

    it "includes shared props from inertia_share" do
      get :index

      # Shared props should always be present, though some may be nil
      expect(inertia.props).to have_key(:helper_widget_host)
      expect(inertia.props).to have_key(:helper_session)
      expect(inertia.props[:is_logged_in]).to eq(false)
      expect(inertia.props[:new_ticket_url]).to be_present
    end
  end

  describe "GET show" do
    let(:article) { HelpCenter::Article.find(43) }

    it "renders the Inertia page with article data" do
      get :show, params: { slug: article.slug }

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq("HelpCenter/Article")
      expect(inertia.props[:article]).to be_present
      expect(inertia.props[:article][:title]).to eq(article.title)
      expect(inertia.props[:article][:slug]).to eq(article.slug)
      expect(inertia.props[:sidebar_categories]).to be_present
      expect(inertia.props[:meta]).to be_present
    end

    it "includes meta information" do
      get :show, params: { slug: article.slug }

      expect(inertia.props[:meta][:title]).to eq("#{article.title} - Gumroad Help Center")
      expect(inertia.props[:meta][:description]).to be_present
      expect(inertia.props[:meta][:canonical_url]).to be_present
    end

    it "includes shared props from inertia_share" do
      get :show, params: { slug: article.slug }

      # Shared props should always be present, though some may be nil
      expect(inertia.props).to have_key(:helper_widget_host)
      expect(inertia.props).to have_key(:helper_session)
      expect(inertia.props[:is_logged_in]).to eq(false)
    end

    context "sidebar_categories" do
      it "uses is_active field" do
        get :show, params: { slug: article.slug }

        sidebar_categories = inertia.props[:sidebar_categories]
        expect(sidebar_categories).to be_an(Array)
        expect(sidebar_categories.first).to include(:is_active)

        active_category = sidebar_categories.find { |c| c[:is_active] }
        expect(active_category).to be_present
        expect(active_category[:slug]).to eq(article.category.slug)
      end
    end

    context "render views" do
      HelpCenter::Article.all.each do |article|
        it "can show article #{article.slug}" do
          get :show, params: { slug: article.slug }

          expect(response).to have_http_status(:ok)
          expect(inertia.props[:article][:title]).to eq(article.title)
          expect(inertia.props[:article][:slug]).to eq(article.slug)
        end
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
