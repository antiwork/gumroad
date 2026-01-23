# frozen_string_literal: true

class HelpCenter::CategoriesController < HelpCenter::BaseController
  def show
    @category = HelpCenter::Category.find_by!(slug: params[:slug])

    articles_data = @category.articles.map do |article|
      {
        title: article.title,
        url: help_center_article_path(article)
      }
    end

    categories_data = @category.categories_for_same_audience.map do |category|
      {
        title: category.title,
        slug: category.slug,
        url: help_center_category_path(category),
        isActive: category == @category
      }
    end

    render inertia: "HelpCenter/Category", props: {
      category: {
        title: @category.title,
        slug: @category.slug,
        articles: articles_data
      },
      categories: categories_data,
      **helper_props
    }
  end
end
