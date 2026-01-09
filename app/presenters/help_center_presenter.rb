# frozen_string_literal: true

class HelpCenterPresenter
  include Rails.application.routes.url_helpers

  attr_reader :view_context

  def initialize(view_context:)
    @view_context = view_context
  end

  def default_url_options
    { host: DOMAIN, protocol: PROTOCOL }
  end

  def index_props
    {
      categories: categories_with_articles
    }
  end

  def article_props(article)
    {
      article: article_data(article),
      sidebar_categories: sidebar_categories_for(article.category),
      meta: article_meta(article)
    }
  end

  def category_props(category)
    {
      category: category_data(category),
      sidebar_categories: sidebar_categories_for(category),
      meta: category_meta(category)
    }
  end

  private
    def categories_with_articles
      HelpCenter::Category.all.map do |category|
        {
          title: category.title,
          slug: category.slug,
          url: help_center_category_path(category),
          audience: category.audience,
          articles: category.articles.map { |article| article_link_data(article) }
        }
      end
    end

    def article_link_data(article)
      {
        title: article.title,
        url: help_center_article_path(article)
      }
    end

    def article_data(article)
      {
        title: article.title,
        slug: article.slug,
        category: category_link_data(article.category)
      }
    end

    def category_data(category)
      {
        title: category.title,
        slug: category.slug,
        articles: category.articles.map { |article| article_link_data(article) }
      }
    end

    def category_link_data(category)
      {
        title: category.title,
        slug: category.slug,
        url: help_center_category_path(category)
      }
    end

    def sidebar_categories_for(reference_category)
      reference_category.categories_for_same_audience.map do |category|
        {
          title: category.title,
          slug: category.slug,
          url: help_center_category_path(category),
          is_active: category == reference_category
        }
      end
    end

    def article_meta(article)
      {
        title: "#{article.title} - Gumroad Help Center",
        description: "Read about #{article.title} in the Gumroad Help Center",
        canonical_url: help_center_article_url(article)
      }
    end

    def category_meta(category)
      {
        title: "#{category.title} - Gumroad Help Center",
        description: "Help articles for #{category.title}",
        canonical_url: help_center_category_url(category)
      }
    end
end
