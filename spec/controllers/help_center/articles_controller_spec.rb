# frozen_string_literal: true

require "spec_helper"

describe HelpCenter::ArticlesController do
  describe "GET index" do
    it "returns http success" do
      get :index

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET show" do
    let(:article) { HelpCenter::Article.find(43) }

    it "returns http success" do
      get :show, params: { slug: article.slug }
      expect(response).to have_http_status(:ok)
    end

    context "render views" do
      render_views

      it "renders the article and categories for the same audience" do
        get :show, params: { slug: article.slug }

        expect(response).to have_http_status(:ok)

        article.category.categories_for_same_audience.each do |c|
          expect(response.body).to include(c.title)
        end

        expect(response.body).to include(article.title)
      end

      HelpCenter::Article.all.each do |article|
        it "renders the article #{article.slug}" do
          get :show, params: { slug: article.slug }

          expect(response).to have_http_status(:ok)
          expect(response.body).to include(ERB::Util.html_escape(article.title))
        end
      end
    end

    context "when article is not found" do
      it "raises ActiveHash::RecordNotFound" do
        expect { get :show, params: { slug: "nonexistent-slug" } }
          .to raise_error(ActiveHash::RecordNotFound)
      end
    end
  end
end
