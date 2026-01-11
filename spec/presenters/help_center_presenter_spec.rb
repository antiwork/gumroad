# frozen_string_literal: true

require "spec_helper"

RSpec.describe HelpCenterPresenter do
  include Rails.application.routes.url_helpers

  def default_url_options
    { host: DOMAIN, protocol: PROTOCOL }
  end

  let(:presenter) { described_class.new }

  describe "#index_props" do
    subject(:props) { presenter.index_props }

    it "returns categories with articles" do
      categories = props[:categories]

      expect(categories).to be_an(Array)
      expect(categories).not_to be_empty

      # Verify structure of first category
      first_category = categories.first
      category_record = HelpCenter::Category.find_by(slug: first_category[:slug])

      expect(first_category).to eq(
        title: category_record.title,
        slug: category_record.slug,
        url: help_center_category_path(category_record),
        audience: category_record.audience,
        articles: category_record.articles.map do |article|
          { title: article.title, url: help_center_article_path(article) }
        end
      )
    end

    it "includes all categories" do
      expect(props[:categories].size).to eq(HelpCenter::Category.count)
    end

    describe "meta" do
      it "returns correct meta information" do
        expect(props[:meta]).to eq(
          title: "Gumroad Help Center",
          description: "Common questions and support documentation",
          canonical_url: help_center_root_url
        )
      end
    end
  end

  describe "#article_props" do
    context "with a creator article" do
      let(:creator_category) { HelpCenter::Category.find_by(audience: "creator") }
      let(:article) { creator_category.articles.first }

      subject(:props) { presenter.article_props(article) }

      describe "article" do
        it "returns article data with category" do
          expect(props[:article]).to eq(
            title: article.title,
            slug: article.slug,
            category: {
              title: article.category.title,
              slug: article.category.slug,
              url: help_center_category_path(article.category)
            }
          )
        end
      end

      describe "sidebar_categories" do
        it "returns only creator categories" do
          sidebar = props[:sidebar_categories]

          expect(sidebar).to be_an(Array)
          expect(sidebar).not_to be_empty

          # All sidebar categories should be for creators
          creator_categories = HelpCenter::Category.where(audience: "creator")
          expect(sidebar.size).to eq(creator_categories.count)
          expect(sidebar.map { |c| c[:slug] }).to match_array(creator_categories.map(&:slug))
        end

        it "marks the article's category as active" do
          active_categories = props[:sidebar_categories].select { |c| c[:is_active] }

          expect(active_categories.size).to eq(1)
          expect(active_categories.first[:slug]).to eq(article.category.slug)
        end

        it "includes correct structure for each category" do
          first_sidebar = props[:sidebar_categories].first
          category_record = HelpCenter::Category.find_by(slug: first_sidebar[:slug])

          expect(first_sidebar).to include(
            title: category_record.title,
            slug: category_record.slug,
            url: help_center_category_path(category_record),
            is_active: (category_record == article.category)
          )
        end
      end

      describe "meta" do
        it "returns correct meta information" do
          expect(props[:meta]).to eq(
            title: "#{article.title} - Gumroad Help Center",
            description: "Read about #{article.title} in the Gumroad Help Center",
            canonical_url: help_center_article_url(article)
          )
        end
      end
    end

    context "with a customer article" do
      let(:customer_category) { HelpCenter::Category.find_by(audience: "customer") }
      let(:article) { customer_category.articles.first }

      subject(:props) { presenter.article_props(article) }

      it "returns only customer categories in sidebar" do
        sidebar = props[:sidebar_categories]
        customer_categories = HelpCenter::Category.where(audience: "customer")

        expect(sidebar.size).to eq(customer_categories.count)
        expect(sidebar.map { |c| c[:slug] }).to match_array(customer_categories.map(&:slug))
      end

      it "does not include creator categories in sidebar" do
        sidebar_slugs = props[:sidebar_categories].map { |c| c[:slug] }
        creator_category_slugs = HelpCenter::Category.where(audience: "creator").map(&:slug)

        creator_category_slugs.each do |creator_slug|
          expect(sidebar_slugs).not_to include(creator_slug)
        end
      end
    end
  end

  describe "#category_props" do
    context "with a creator category" do
      let(:category) { HelpCenter::Category.find_by(audience: "creator") }

      subject(:props) { presenter.category_props(category) }

      describe "category" do
        it "returns category data with articles" do
          expect(props[:category]).to eq(
            title: category.title,
            slug: category.slug,
            articles: category.articles.map do |article|
              { title: article.title, url: help_center_article_path(article) }
            end
          )
        end
      end

      describe "sidebar_categories" do
        it "returns only creator categories" do
          sidebar = props[:sidebar_categories]
          creator_categories = HelpCenter::Category.where(audience: "creator")

          expect(sidebar.size).to eq(creator_categories.count)
          expect(sidebar.map { |c| c[:slug] }).to match_array(creator_categories.map(&:slug))
        end

        it "marks the current category as active" do
          active_categories = props[:sidebar_categories].select { |c| c[:is_active] }

          expect(active_categories.size).to eq(1)
          expect(active_categories.first[:slug]).to eq(category.slug)
        end
      end

      describe "meta" do
        it "returns correct meta information" do
          expect(props[:meta]).to eq(
            title: "#{category.title} - Gumroad Help Center",
            description: "Help articles for #{category.title}",
            canonical_url: help_center_category_url(category)
          )
        end
      end
    end

    context "with a customer category" do
      let(:category) { HelpCenter::Category.find_by(audience: "customer") }

      subject(:props) { presenter.category_props(category) }

      it "returns only customer categories in sidebar" do
        sidebar = props[:sidebar_categories]
        customer_categories = HelpCenter::Category.where(audience: "customer")

        expect(sidebar.size).to eq(customer_categories.count)
        expect(sidebar.map { |c| c[:slug] }).to match_array(customer_categories.map(&:slug))
      end
    end
  end
end
