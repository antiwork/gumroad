# frozen_string_literal: true

class HelpCenterPresenter
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
      article: {
        title: article.title,
        slug: article.slug,
        content: view_context.render(article),
        category: category_data(article.category)
      },
      sidebar_categories: same_audience_categories_data(article.category)
    }
  end

  def category_props(category)
    {
      category: {
        title: category.title,
        slug: category.slug,
        articles: category.articles.map { |article| article_link_data(article) }
      },
      sidebar_categories: same_audience_categories_data(category)
    }
  end

  private
    def categories_with_articles
      HelpCenter::Category.all.map do |category|
        {
          title: category.title,
          url: view_context.help_center_category_path(category),
          audience: category.audience,
          articles: category.articles.map { |article| article_link_data(article) }
        }
      end
    end

    def article_link_data(article)
      {
        title: article.title,
        url: view_context.help_center_article_path(article)
      }
    end

    def same_audience_categories_data(category)
      category.categories_for_same_audience.map { |cat| category_data(cat) }
    end

    def category_data(category)
      {
        title: category.title,
        slug: category.slug,
        url: view_context.help_center_category_path(category)
      }
    end
end
