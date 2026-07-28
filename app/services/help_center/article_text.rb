# frozen_string_literal: true

# HelpCenter::ArticleText turns a help center article — which is stored as an ERB partial of
# marked-up HTML under app/views/help_center/articles/contents/ — into plain text a program can
# read.
#
# Why this exists: the store agent (see Ai::StoreAgentService) used to have no way to look up how
# Gumroad actually works, so when a creator asked about something the agent had no API endpoint
# for, it answered from its own guesses and sometimes told the creator a supported feature did not
# exist at all. The help center is the documentation the support team keeps accurate, so giving
# the agent read access to it is the cheapest way to stop those wrong answers. The v2 endpoints in
# Api::V2::HelpArticlesController expose this text; the agent reads it like any other API.
#
# The HTML is stripped rather than passed through because the articles are written for browsers:
# they carry navigation lists, anchor markup, and screenshots (some inlined as base64 data URLs
# hundreds of kilobytes long). None of that helps a language model, and the base64 alone would
# blow past any sane response size.
module HelpCenter::ArticleText
  # Upper bound on the plain text RETURNED for one article. Applied when the text is handed out,
  # not when it is cached, so a term deep in a long article is still findable by search (see
  # #search) even though a reader gets a capped excerpt. The longest articles are long because of
  # embedded images, which we drop, so real prose lands well below this; the cap only guards
  # against an unusually long article filling the agent's context.
  MAX_LENGTH = 12_000

  # Elements whose text is noise (or enormous) once the page is reduced to prose.
  IGNORED_SELECTORS = "script, style, figure, img, svg, iframe, video, source"

  # Where the article partials live. Used to date them for the cache key (see #cache_version).
  CONTENTS_GLOB = "app/views/help_center/articles/contents/*.html.erb"

  # Words dropped from a query before matching. Callers here are programs writing questions — the
  # store agent is told to search the help center in the creator's own words — and a question
  # carries function words that say nothing about the topic. Because a result has to match EVERY
  # term (see #search), one such word that happens to be absent from an article's text rules the
  # article out: "how do I change my store colors" found nothing while "change store colors" found
  # the article that answers it. Zero results is the one answer this endpoint exists to prevent,
  # since the agent reads it as "Gumroad cannot do this" and tells the creator so.
  #
  # Deliberately limited to function words with no topical meaning. Product vocabulary is never
  # listed, and short words that matter on Gumroad ("VAT", "tax", "PDF") are not touched.
  STOPWORDS = %w[
    a an and any are as at be been by can could do does doing for from get got had has have how
    i if in into is it its me my of on or our so that the their them then there these this to
    us was were what when where which who why will with would you your
  ].to_set.freeze

  module_function

  # The article as plain text for a reader, capped at MAX_LENGTH with a pointer to the live page.
  def for(article)
    plain_text(article).truncate(
      MAX_LENGTH,
      omission: "\n\n[Article truncated. Read the rest at #{article_url(article)}]"
    )
  end

  # The article's COMPLETE plain text, cached. Rendering the ERB and parsing the HTML costs real
  # time, and search reads every article, so this has to be cheap on the second call. The deploy
  # revision is part of the key: the articles are code, so the only way one changes is a deploy,
  # and without the revision an edited article could keep serving its pre-edit text — exactly the
  # staleness these endpoints exist to remove. (Production already namespaces the whole cache by
  # revision; keying it here means development and any other environment behave the same way.)
  def plain_text(article)
    Rails.cache.fetch("help_center/article_text/#{cache_version}/#{article.slug}") { render_plain_text(article) }
  end

  # Identifies the deployed code, so a deploy that edits an article invalidates its cached text.
  # REVISION is the deployed git sha in staging and production; elsewhere it is a fixed sentinel
  # ("no-revision"), so development and test fall back to the newest mtime among the article
  # partials themselves and pick up a local edit at once.
  #
  # It has to be the files' mtimes and not the containing directory's: a directory's mtime only
  # moves when an entry is added, removed, or renamed, so editing the text of an article that
  # already exists would leave the key unchanged and keep serving the pre-edit prose — the exact
  # staleness these endpoints exist to remove. Reading a few dozen mtimes is cheap, and this path
  # never runs in production.
  def cache_version
    return REVISION if defined?(REVISION) && REVISION.present? && REVISION != "no-revision"

    newest = Dir[Rails.root.join(CONTENTS_GLOB)].map { |path| File.mtime(path).to_i }.max
    newest ? "dev-#{newest}" : "dev"
  rescue SystemCallError
    "dev"
  end

  # A compact listing of every article: what it is called, what it covers, and the slug the
  # caller passes back to read it in full.
  def index
    HelpCenter::Article.all.map { |article| summary(article) }
  end

  # Articles matching every meaningful word in `query` (case-insensitively), so "product page
  # colors" narrows rather than widens the result.
  #
  # The query is split on anything that is not a letter or digit rather than on whitespace,
  # because callers write questions, not keyword lists. Splitting on whitespace kept the
  # punctuation inside the term, so "store colors?" searched for the literal "colors?" and matched
  # nothing — the caller would conclude Gumroad has no documentation on store colors, which is the
  # exact wrong answer this endpoint was added to prevent.
  #
  # Function words are then dropped (see STOPWORDS) for the same reason. Every remaining term has
  # to match, so a single question word absent from an article's prose is enough to hide the
  # article that answers the question: "how do I change my store colors" returned nothing while
  # "change store colors" returned the right article. If a query is nothing but function words,
  # the words are kept rather than matching everything — searching "how do I" narrowing to the
  # whole help center would be noise, not an answer.
  #
  # Matching covers the article's full text, not just its title and description. That costs more —
  # it renders every article once, then reads them from the cache — but title-only matching made
  # the endpoint useless for the thing it exists for: a caller searching a word that appears in the
  # body but not the headline ("theme", "payout schedule") got zero results and would reasonably
  # conclude Gumroad has nothing to say about it, which is the exact wrong answer this endpoint was
  # added to prevent. Titles and descriptions still rank first so the closest match leads.
  def search(query)
    words = query.to_s.downcase.scan(/[[:alnum:]]+/)
    return index if words.empty?

    terms = words.reject { |word| STOPWORDS.include?(word) }
    terms = words if terms.empty?

    headline, body = HelpCenter::Article.all.each_with_object([[], []]) do |article, (headline_hits, body_hits)|
      heading = "#{article.title} #{article.description}".downcase
      next headline_hits << summary(article) if terms.all? { |term| heading.include?(term) }

      full = "#{heading} #{plain_text(article).downcase}"
      body_hits << summary(article) if terms.all? { |term| full.include?(term) }
    end

    headline + body
  end

  def summary(article)
    {
      slug: article.slug,
      title: article.title,
      description: article.description,
      category: article.category&.title,
      audience: article.category&.audience,
      url: article_url(article),
    }
  end

  def article_url(article)
    "#{PROTOCOL}://#{DOMAIN}/help/article/#{article.slug}"
  end

  def render_plain_text(article)
    html = ApplicationController.render(partial: article.to_partial_path)
    document = Nokogiri::HTML::DocumentFragment.parse(html)
    document.css(IGNORED_SELECTORS).each(&:remove)
    # Put each block element's text on its own line: without this, a list of six links collapses
    # into one run-on sentence that reads as a single unrelated phrase.
    document.css("p, li, h1, h2, h3, h4, h5, h6, tr, div, br").each { |node| node.add_next_sibling("\n") }

    document.text.gsub(/[ \t]+/, " ").gsub(/ ?\n ?/, "\n").gsub(/\n{3,}/, "\n\n").strip
  end
end
