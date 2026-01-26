# frozen_string_literal: true

class HelpCenter::ArticlesController < HelpCenter::BaseController
  before_action :redirect_legacy_articles, only: :show

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

    title = "Gumroad Help Center"
    description = "Common questions and support documentation"
    canonical_url = help_center_root_url

    set_meta_tag(title: title)
    set_meta_tag(tag_name: "link", rel: "canonical", href: canonical_url, head_key: "canonical")
    set_meta_tag(name: "description", content: description)

    set_meta_tag(property: "og:title", value: title)
    set_meta_tag(property: "og:description", value: description)
    set_meta_tag(property: "og:url", content: canonical_url)

    set_meta_tag(name: "twitter:title", content: title)
    set_meta_tag(name: "twitter:description", content: description)
  end

  def show
    @article = HelpCenter::Article.find_by!(slug: params[:slug])

    title = "#{@article.title} - Gumroad Help Center"
    canonical_url = help_center_article_url(@article)

    set_meta_tag(title: title)
    set_meta_tag(tag_name: "link", rel: "canonical", href: canonical_url, head_key: "canonical")

    set_meta_tag(property: "og:title", value: title)
    set_meta_tag(property: "og:url", content: canonical_url)

    set_meta_tag(name: "twitter:title", content: title)
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
