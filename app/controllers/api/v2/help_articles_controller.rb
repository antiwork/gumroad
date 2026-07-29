# frozen_string_literal: true

# Read-only access to Gumroad's own help center articles (the pages served at
# gumroad.com/help/article/<slug>), so a program can look up how Gumroad actually works instead of
# guessing.
#
# This is the store agent's documentation lookup. The agent drives the public v2 API for everything
# it does (see Ai::StoreAgentApiClient), and before these endpoints existed it had no way to check a
# product question against a source of truth: asked about anything it had no write endpoint for, it
# answered from its own assumptions, and in the worst case told a creator a feature they were
# already using did not exist. The help center is documentation the support team keeps correct, so
# reading it is what makes the agent's answers checkable.
#
# The content is public — these are pages anyone can read without an account — so the only scope
# required is the baseline read scope every token carries. Nothing here touches seller data.
class Api::V2::HelpArticlesController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }

  # List (or keyword-search) the articles as title + description + slug, so the caller can pick the
  # right one to read in full. Deliberately excludes bodies: the whole help center is far too large
  # to hand back in one response.
  def index
    expires_in 1.hour

    articles = params[:query].present? ? HelpCenter::ArticleText.search(params[:query]) : HelpCenter::ArticleText.index
    render_response(true, help_articles: articles, count: articles.length)
  end

  # One article's full text, HTML stripped down to prose.
  def show
    article = HelpCenter::Article.find_by(slug: params[:slug])
    return render_response(false, message: "The help article was not found. Call the list endpoint to see the available slugs.") if article.nil?

    expires_in 1.hour

    render_response(true, help_article: HelpCenter::ArticleText.summary(article).merge(content: HelpCenter::ArticleText.for(article)))
  end
end
