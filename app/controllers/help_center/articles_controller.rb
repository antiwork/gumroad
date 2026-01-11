# frozen_string_literal: true

class HelpCenter::ArticlesController < HelpCenter::BaseController
  before_action :redirect_legacy_articles, only: :show

  def index
    @title = "Gumroad Help Center"
    render inertia: "HelpCenter/Index", props: help_center_presenter.index_props
  end

  def show
    article = HelpCenter::Article.find_by!(slug: params[:slug])
    @title = "#{article.title} - Gumroad Help Center"
    render inertia: "HelpCenter/Article/Show", props: help_center_presenter.article_props(article)
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
