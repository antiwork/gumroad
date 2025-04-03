# frozen_string_literal: true

class Referrer
  DEFAULT_VALUE = "direct"

  def self.extract_domain(url)
    return DEFAULT_VALUE if url.blank? || url == "direct"

    domain = begin
      url = URI::DEFAULT_PARSER.unescape(url)
      url.encode!("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "")
      url.gsub!(/\s+/, "")
      host = URI.parse(url).host.try(:downcase)
      return DEFAULT_VALUE if host.blank?

      host.start_with?("www.") ? host[4..-1] : host
    rescue URI::InvalidURIError, Encoding::CompatibilityError
    end

    domain.presence || DEFAULT_VALUE
  end
end
