# frozen_string_literal: true

require "spec_helper"

describe HelpCenter::CategoriesController do
  describe "GET show" do
    let(:category) { HelpCenter::Category.first }

    context "render views" do
      render_views

      it "lists the category's articles and other categories for the same audience" do
        get :show, params: { slug: category.slug }

        expect(response).to have_http_status(:ok)

        category.categories_for_same_audience.each do |c|
          expect(response.body).to include(c.title)
        end

        category.articles.each do |a|
          expect(response.body).to include(a.title)
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
