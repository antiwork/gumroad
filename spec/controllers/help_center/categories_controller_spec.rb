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
      it "raises ActiveHash::RecordNotFound" do
        expect { get :show, params: { slug: "nonexistent-slug" } }
          .to raise_error(ActiveHash::RecordNotFound)
      end
    end
  end
end
