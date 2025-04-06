# frozen_string_literal: true

class HelpController < ApplicationController
  layout "help"

  def index
    @page_title = "Gumroad Help Center"
  end

  def category
    category_id = params[:id]
    @category_file = File.join(Rails.root, "public", "help", "category", "#{category_id}.html")

    if File.exist?(@category_file)
      @page_content = parse_html_content(@category_file)
      @page_title = @page_content[:title]
    else
      redirect_to help_path, alert: "Category not found"
    end
  end

  def article
    article_id = params[:id]
    @article_file = File.join(Rails.root, "public", "help", "article", "#{article_id}.html")

    if File.exist?(@article_file)
      @page_content = parse_html_content(@article_file)
      @page_title = @page_content[:title]
    else
      redirect_to help_path, alert: "Article not found"
    end
  end

  private

  def parse_html_content(file_path)
    content = File.read(file_path)
    doc = Nokogiri::HTML(content)

    # Extract the title from the HTML
    title = doc.at_css("title")&.content&.gsub(" - Gumroad Help Center", "") || "Help Center"

    # Extract the main content
    main_content = if file_path.include?("category")
      doc.at_css("#categoryHead, .articleList")
    else
      doc.at_css("#fullArticle")
    end

    # Extract breadcrumbs if available
    breadcrumbs = doc.at_css(".breadcrumbs")

    # Extract sidebar if available
    sidebar = doc.at_css(".sidebar")

    {
      title: title,
      main_content: main_content&.to_html,
      breadcrumbs: breadcrumbs&.to_html,
      sidebar: sidebar&.to_html
    }
  end
end
