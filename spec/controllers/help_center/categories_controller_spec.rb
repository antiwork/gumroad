# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe HelpCenter::CategoriesController, inertia: true do
  describe "GET show" do
    let(:category) { HelpCenter::Category.first }

    it "returns http success and renders Inertia component" do
      get :show, params: { slug: category.slug }

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq("HelpCenter/Category")
      expect(inertia.props[:category][:title]).to eq(category.title)
      expect(inertia.props[:category][:slug]).to eq(category.slug)
    end

    it "lists the category's articles" do
      get :show, params: { slug: category.slug }

      article_titles = inertia.props[:category][:articles].map { |a| a[:title] }
      category.articles.each do |a|
        expect(article_titles).to include(a.title)
      end
    end

    it "includes categories for the same audience in sidebar" do
      get :show, params: { slug: category.slug }

      category_titles = inertia.props[:categories].map { |c| c[:title] }
      category.categories_for_same_audience.each do |c|
        expect(category_titles).to include(c.title)
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
