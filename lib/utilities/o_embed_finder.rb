# frozen_string_literal: true

class OEmbedFinder
  SOUNDCLOUD_PARAMS = %w[auto_play show_artwork show_comments buying sharing download show_playcount show_user liking].freeze

  # limited oembed urls for mobile (we don't know if mobile can support other urls)
  MOBILE_URL_REGEXES = [%r{player.vimeo.com/video/\d+}, %r{https://w.soundcloud.com/player}, %r{https://www.youtube.com/embed}].freeze

  # Providers are registered once at boot, in config/initializers/oembed.rb.
  def self.embeddable_from_url(new_url, maxwidth = AssetPreview::DEFAULT_DISPLAY_WIDTH)
    res = begin
      OEmbed::Providers.get(new_url, maxwidth:)
    rescue StandardError
      return nil
    end

    if res.video? || res.rich?
      html = res.html
      if /api.soundcloud.com/.match?(html)
        html = html.gsub("http://w.soundcloud.com", "https://w.soundcloud.com")
        payload = SOUNDCLOUD_PARAMS.map { |k| "#{k}=false" }.join("&")
        html = html.gsub(/show_artwork=true/, payload)
      elsif %r{youtube.com/embed}.match?(html)
        html = html.gsub("http://", "https://")
        html = html.gsub(/feature=oembed/, "feature=oembed&showinfo=0&controls=0&rel=0")
      elsif html.include?("wistia")
        html = html.gsub("http://", "https://")
      elsif html.include?("sketchfab")
        html = html.gsub("http://", "https://")
      elsif html.include?("vimeo")
        html = html.gsub("http://", "https://")
      end

      info_fields = %w[width height thumbnail_url]
      fields = res.fields.select { |k, _v| info_fields.include?(k) }
      { html:, info: fields }
    end
  end
end
