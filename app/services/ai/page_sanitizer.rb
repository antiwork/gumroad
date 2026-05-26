# frozen_string_literal: true

require "addressable/uri"
require "cgi"

class Ai::PageSanitizer
  ALLOWED_SCRIPT_HOSTS = %w[
    cdn.tailwindcss.com
    cdn.jsdelivr.net
    unpkg.com
  ].freeze

  ALLOWED_STYLESHEET_HOSTS = %w[
    fonts.googleapis.com
    fonts.bunny.net
  ].freeze

  ALLOWED_TAGS = %w[
    a abbr address area article aside audio b bdi bdo blockquote br button canvas caption cite code col colgroup data datalist dd del details dfn dialog div dl dt em
    head html
    fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr i iframe img input ins kbd label legend li link main map mark menu meter nav ol optgroup option
    output p picture pre progress q rp rt ruby s samp script search section select slot small source span strong style sub summary sup svg table tbody td template textarea
    tfoot th thead time tr track u ul var video wbr path circle rect line polyline polygon ellipse g defs linearGradient radialGradient stop clipPath
  ].freeze

  ALLOWED_ATTRIBUTES = %w[
    accept accept-charset action alt aria-describedby aria-hidden aria-label aria-labelledby aria-live aria-pressed async autocomplete autofocus autoplay checked cite class
    charset cols colspan content contenteditable controls coords crossorigin data-gumroad-action data-gumroad-field datetime defer dir disabled download draggable enctype
    fill for form height hidden href id kind label lang loading loop max maxlength media method min minlength multiple muted name pattern placeholder playsinline poster
    preserveAspectRatio readonly rel required role rows rowspan sandbox scope selected shape size sizes span spellcheck src srcset step style tabindex target title translate type
    value viewBox width xmlns x y x1 y1 x2 y2 cx cy r rx ry d stroke stroke-width stroke-linecap stroke-linejoin fill-rule clip-rule points transform offset stop-color
    stop-opacity
  ].freeze

  URL_ATTRIBUTES = %w[action href poster src xlink:href].freeze
  WRAPPER_TAGS = %w[html head body].freeze

  def self.sanitize(html)
    return "" if html.blank?

    fragment = Loofah.fragment(html)
    scrub_node(fragment)
    fragment.to_html
  end

  def self.scrub_node(node)
    node.children.to_a.each { |child| scrub_node(child) }
    return unless node.element?

    if WRAPPER_TAGS.include?(node.name)
      node.replace(node.children)
      return
    end

    if node.name == "meta" && node["http-equiv"].to_s.casecmp("refresh").zero?
      node.remove
      return
    end

    unless ALLOWED_TAGS.include?(node.name)
      node.remove
      return
    end

    if node.name == "script" && node["src"].present? && !allowed_script_src?(node["src"])
      node.remove
      return
    end

    if node.name == "link" && !allowed_stylesheet_link?(node)
      node.remove
      return
    end

    node["sandbox"] = "allow-scripts" if node.name == "iframe" && node["sandbox"].blank?
    node.remove_attribute("action") if node.name == "form"

    node.attribute_nodes.each do |attribute|
      name = attribute.name
      next if allowed_attribute?(name) && !dangerous_url_attribute?(name, attribute.value)

      node.remove_attribute(name)
    end
  end

  def self.allowed_attribute?(name)
    name.start_with?("data-", "aria-", "on") || ALLOWED_ATTRIBUTES.include?(name)
  end

  def self.dangerous_url_attribute?(name, value)
    return false unless URL_ATTRIBUTES.include?(name)

    normalized = normalize_url(value)
    normalized.start_with?("javascript:") || normalized.start_with?("data:text/html")
  end

  def self.allowed_script_src?(src)
    https_host_in?(src, ALLOWED_SCRIPT_HOSTS)
  end

  def self.allowed_stylesheet_link?(node)
    return false unless node["rel"].to_s.downcase.split(/\s+/).include?("stylesheet")

    https_host_in?(node["href"], ALLOWED_STYLESHEET_HOSTS)
  end

  def self.https_host_in?(url, hosts)
    return false if url.blank?

    uri = URI.parse(url)
    uri.scheme == "https" && hosts.include?(uri.host)
  rescue URI::InvalidURIError
    false
  end

  def self.normalize_url(value)
    decoded = CGI.unescapeHTML(value.to_s)
    3.times do
      decoded = Addressable::URI.unencode_component(decoded)
    rescue Addressable::URI::InvalidURIError
      break
    end
    decoded.gsub(/[[:space:]\u0000-\u001f]+/, "").downcase
  end

  private_class_method :scrub_node, :allowed_attribute?, :dangerous_url_attribute?, :allowed_script_src?, :allowed_stylesheet_link?, :https_host_in?, :normalize_url
end
