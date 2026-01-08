# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe HelpCenter::CategoriesController, type: :controller, inertia: true do
  render_views

  describe "GET show" do
    let(:category) { HelpCenter::Category.first }

    it "renders the Inertia page with category data" do
      get :show, params: { slug: category.slug }

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq("HelpCenter/Category")
      expect(inertia.props[:category]).to be_present
      expect(inertia.props[:category][:title]).to eq(category.title)
      expect(inertia.props[:category][:articles]).to be_present
      expect(inertia.props[:sidebar_categories]).to be_present
      expect(inertia.props[:meta]).to be_present
    end

    it "includes meta information" do
      get :show, params: { slug: category.slug }

      expect(inertia.props[:meta][:title]).to eq("#{category.title} - Gumroad Help Center")
      expect(inertia.props[:meta][:description]).to be_present
      expect(inertia.props[:meta][:canonical_url]).to be_present
    end

    it "includes shared props from inertia_share" do
      get :show, params: { slug: category.slug }

      # Shared props should always be present, though some may be nil
      expect(inertia.props).to have_key(:helper_widget_host)
      expect(inertia.props).to have_key(:helper_session)
      expect(inertia.props[:is_logged_in]).to eq(false)
    end

    context "sidebar_categories" do
      it "uses is_active field" do
        get :show, params: { slug: category.slug }

        sidebar_categories = inertia.props[:sidebar_categories]
        expect(sidebar_categories).to be_an(Array)
        expect(sidebar_categories.first).to include(:is_active)

        active_category = sidebar_categories.find { |c| c[:is_active] }
        expect(active_category).to be_present
        expect(active_category[:slug]).to eq(category.slug)
      end
    end

    context "render views" do
      it "includes the category's articles and sidebar categories in props" do
        get :show, params: { slug: category.slug }

        expect(response).to have_http_status(:ok)

        sidebar_category_titles = inertia.props[:sidebar_categories].map { |c| c[:title] }
        category.categories_for_same_audience.each do |c|
          expect(sidebar_category_titles).to include(c.title)
        end

        article_titles = inertia.props[:category][:articles].map { |a| a[:title] }
        category.articles.each do |a|
          expect(article_titles).to include(a.title)
        end
      end
    end

    context "when category is not found" do
      it "redirects to the help center root path" do
        get :show, params: { slug: "nonexistent-slug" }

        expect(response).to redirect_to(help_center_root_path)
        expect(response).to have_http_status(:found)
      end
    end
  end
end
