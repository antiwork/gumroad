# frozen_string_literal: true

class HelpCenter::ArticlesController < HelpCenter::BaseController
  before_action :redirect_legacy_articles, only: :show

  def index
    title = "Gumroad Help Center"
    description = "Common questions and support documentation"
    canonical_url = help_center_root_url

    set_meta_tag(title:)
    set_meta_tag(tag_name: "link", rel: "canonical", href: canonical_url, head_key: "canonical")
    set_meta_tag(name: "description", content: description)

    set_meta_tag(property: "og:title", value: title)
    set_meta_tag(property: "og:description", value: description)
    set_meta_tag(property: "og:url", value: canonical_url)

    set_meta_tag(name: "twitter:title", content: title)
    set_meta_tag(name: "twitter:description", content: description)

    render inertia: "HelpCenter/Articles/Index", props: help_center_presenter.index_props
  end

  def show
    article = HelpCenter::Article.find_by!(slug: params[:slug])

    title = "#{article.title} - Gumroad Help Center"
    canonical_url = help_center_article_url(article)

    set_meta_tag(title:)
    set_meta_tag(tag_name: "link", rel: "canonical", href: canonical_url, head_key: "canonical")

    set_meta_tag(property: "og:title", value: title)
    set_meta_tag(property: "og:url", value: canonical_url)

    set_meta_tag(name: "twitter:title", content: title)

    render inertia: "HelpCenter/Articles/Show", props: help_center_presenter.article_props(article)
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
