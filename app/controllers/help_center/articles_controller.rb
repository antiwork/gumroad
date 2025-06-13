# frozen_string_literal: true

class HelpCenter::ArticlesController < HelpCenter::BaseController
  def index
    @props = {
      categories: HelpCenter::Category.all.map do |category|
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
    }

    @title = "Gumroad Help Center"
    @canonical_url = help_center_root_url
    @description = "Common questions and support documentation"
  end

  def show
    @article = HelpCenter::Article.find_by!(slug: params[:slug])

    @title = "#{@article.title} - Gumroad Help Center"
    @canonical_url = help_center_article_url(@article)
  end
end
