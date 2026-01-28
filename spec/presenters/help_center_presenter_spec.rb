# frozen_string_literal: true

require "spec_helper"

describe HelpCenterPresenter do
  let(:view_context) do
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    controller.request.host = DOMAIN
    controller.view_context
  end
  subject(:presenter) { described_class.new(view_context:) }

  describe "#index_props" do
    it "returns categories with articles" do
      props = presenter.index_props

      expect(props[:categories]).to be_an(Array)
      expect(props[:categories]).not_to be_empty
      expect(props[:categories].first).to include(:title, :url, :audience, :articles)
    end
  end

  describe "#article_props" do
    let(:article) { HelpCenter::Article.first }

    it "returns article data with category and content" do
      props = presenter.article_props(article)

      expect(props[:article]).to include(
        title: article.title,
        slug: article.slug
      )
      expect(props[:article][:content]).to be_a(String)
      expect(props[:article][:content]).not_to be_empty
      expect(props[:article][:category]).to include(:title, :slug, :url)
    end

    it "returns sidebar categories" do
      props = presenter.article_props(article)

      expect(props[:sidebar_categories]).to be_an(Array)
      expect(props[:sidebar_categories].first).to include(:title, :slug, :url)
    end
  end

  describe "#category_props" do
    let(:category) { HelpCenter::Category.first }

    it "returns category data with articles" do
      props = presenter.category_props(category)

      expect(props[:category]).to include(
        title: category.title,
        slug: category.slug
      )
      expect(props[:category][:articles]).to be_an(Array)
    end

    it "returns sidebar categories" do
      props = presenter.category_props(category)

      expect(props[:sidebar_categories]).to be_an(Array)
      expect(props[:sidebar_categories].first).to include(:title, :slug, :url)
    end
  end
end
