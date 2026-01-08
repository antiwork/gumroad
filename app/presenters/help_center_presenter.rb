# frozen_string_literal: true

class HelpCenterPresenter
  include Rails.application.routes.url_helpers

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
      article: article_data(article),
      sidebar_categories: sidebar_categories_for(article.category),
      meta: article_meta(article)
    }
  end

  def category_props(category)
    {
      category: category_data(category),
      sidebar_categories: sidebar_categories_for(category),
      meta: category_meta(category)
    }
  end

  private
    def categories_with_articles
      HelpCenter::Category.all.map do |category|
        {
          title: category.title,
          url: help_center_category_path(category),
          audience: category.audience,
          articles: category.articles.map { |article| article_link_data(article) }
        }
      end
    end

    def article_link_data(article)
      {
        title: article.title,
        url: help_center_article_path(article)
      }
    end

    def article_data(article)
      {
        title: article.title,
        slug: article.slug,
        content: render_article_content(article),
        category: category_link_data(article.category)
      }
    end

    def category_data(category)
      {
        title: category.title,
        slug: category.slug,
        articles: category.articles.map { |article| article_link_data(article) }
      }
    end

    def category_link_data(category)
      {
        title: category.title,
        slug: category.slug,
        url: help_center_category_path(category)
      }
    end

    def sidebar_categories_for(reference_category)
      reference_category.categories_for_same_audience.map do |category|
        {
          title: category.title,
          slug: category.slug,
          url: help_center_category_path(category),
          is_active: category == reference_category
        }
      end
    end

    def render_article_content(article)
      html = view_context.render(partial: article.to_partial_path, layout: false)
      post_process_internal_links(html)
    end

    def post_process_internal_links(html)
      # Convert relative article links to full paths
      # e.g., href="128-discount-codes" -> href="/help/article/128-discount-codes"
      html.gsub(/href="(\d+-[^"]+)"/) do |_match|
        slug = ::Regexp.last_match(1)
        %{href="#{help_center_article_path(slug)}"}
      end
    end

    def article_meta(article)
      {
        title: "#{article.title} - Gumroad Help Center",
        description: extract_description_from_content(article),
        canonical_url: help_center_article_url(article)
      }
    end

    def category_meta(category)
      {
        title: "#{category.title} - Gumroad Help Center",
        description: "Help articles for #{category.title}",
        canonical_url: help_center_category_url(category)
      }
    end

    def extract_description_from_content(article)
      # First, try to get @description from the rendered partial
      # Article partials set @description in the first line like:
      # <% @description = "In this article: ..." %>
      # But we can't access it directly, so we extract from rendered content
      content = view_context.render(partial: article.to_partial_path, layout: false)
      plain_text = ActionController::Base.helpers.strip_tags(content).squish
      plain_text.truncate(160)
    end
end
