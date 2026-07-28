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
  # Upper bound on the plain text returned for one article. The longest articles are long because
  # of embedded images, which we drop, so real prose lands far below this; the cap only guards
  # against an unusually long article filling the agent's context.
  MAX_LENGTH = 12_000

  # Elements whose text is noise (or enormous) once the page is reduced to prose.
  IGNORED_SELECTORS = "script, style, figure, img, svg, iframe, video, source"

  module_function

  # The article rendered to plain text, with paragraphs and list items on their own lines.
  # Cached because rendering the ERB and parsing the HTML costs real time and the content only
  # changes when the partial itself is edited and deployed.
  def for(article)
    Rails.cache.fetch("help_center/article_text/v1/#{article.slug}") { render_plain_text(article) }
  end

  # A compact listing of every article: what it is called, what it covers, and the slug the
  # caller passes back to read it in full.
  def index
    HelpCenter::Article.all.map { |article| summary(article) }
  end

  # Articles whose title or description matches every whitespace-separated term in `query`
  # (case-insensitive), so "product page colors" narrows rather than widens the result. Matching
  # deliberately looks at the title and description only, not the full body: descriptions are the
  # article's own opening lines, and searching 100+ full articles per query would be far more
  # expensive than the caller reading the one or two that look right.
  def search(query)
    terms = query.to_s.downcase.split(/\s+/).reject(&:blank?)
    return index if terms.empty?

    HelpCenter::Article.all.filter_map do |article|
      haystack = "#{article.title} #{article.description}".downcase
      summary(article) if terms.all? { |term| haystack.include?(term) }
    end
  end

  def summary(article)
    {
      slug: article.slug,
      title: article.title,
      description: article.description,
      category: article.category&.title,
      audience: article.category&.audience,
      url: "#{PROTOCOL}://#{DOMAIN}/help/article/#{article.slug}",
    }
  end

  def render_plain_text(article)
    html = ApplicationController.render(partial: article.to_partial_path)
    document = Nokogiri::HTML::DocumentFragment.parse(html)
    document.css(IGNORED_SELECTORS).each(&:remove)
    # Put each block element's text on its own line: without this, a list of six links collapses
    # into one run-on sentence that reads as a single unrelated phrase.
    document.css("p, li, h1, h2, h3, h4, h5, h6, tr, div, br").each { |node| node.add_next_sibling("\n") }

    text = document.text.gsub(/[ \t]+/, " ").gsub(/ ?\n ?/, "\n").gsub(/\n{3,}/, "\n\n").strip
    text.truncate(MAX_LENGTH, omission: "\n\n[Article truncated. Read the rest at #{PROTOCOL}://#{DOMAIN}/help/article/#{article.slug}]")
  end
end
