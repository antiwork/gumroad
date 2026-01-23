# frozen_string_literal: true

class HelpCenter::ArticlesController < HelpCenter::BaseController
  before_action :redirect_legacy_articles, only: :show

  def index
    categories_data = HelpCenter::Category.all.map do |category|
      {
        title: category.title,
        url: help_center_category_path(category),
        audience: category.audience,
        articles: category.articles.map do |article|
          {
            title: article.title,
            url: help_center_article_path(article)
          }
        end
      }
    end

    render inertia: "HelpCenter/Index", props: {
      categories: categories_data,
      **helper_props
    }
  end

  def show
    @article = HelpCenter::Article.find_by!(slug: params[:slug])

    content_html = render_to_string(partial: @article.to_partial_path, formats: [:html])

    categories_data = @article.category.categories_for_same_audience.map do |category|
      {
        title: category.title,
        slug: category.slug,
        url: help_center_category_path(category),
        isActive: category == @article.category
      }
    end

    render inertia: "HelpCenter/Article", props: {
      article: {
        title: @article.title,
        slug: @article.slug,
        content_html: content_html
      },
      categories: categories_data,
      **helper_props
    }
  end

  private
    LEGACY_ARTICLE_REDIRECTS = {
      "284-jobs-at-gumroad" => "/about#jobs"
    }

    def redirect_legacy_articles
      return unless LEGACY_ARTICLE_REDIRECTS.key?(params[:slug])

      redirect_to LEGACY_ARTICLE_REDIRECTS[params[:slug]], status: :moved_permanently
    end
end
