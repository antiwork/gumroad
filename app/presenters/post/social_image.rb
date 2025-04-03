# frozen_string_literal: true

class Post::SocialImage
  class << self
    alias_method :for, :new
  end

  def initialize(content)
    @content = content
  end

  def url
    first_figure_with_image&.at("img")&.attr("src")
  end

  def caption
    first_figure_with_image&.at(".figcaption")&.text
  end

  def blank?
    url.blank?
  end

  private
    attr_reader :content

    def first_figure_with_image
      @_first_figure_with_image ||= Nokogiri::HTML(content).at_xpath("//figure//img/ancestor::figure")
    rescue => e
      Bugsnag.notify(e)
      nil
    end
end
