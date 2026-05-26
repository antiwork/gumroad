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

  # `html`/`head`/`body` are intentionally absent — they're handled first by
  # the WRAPPER_TAGS unwrap in scrub_node, so listing them here would be dead,
  # misleading allowlist entries.
  ALLOWED_TAGS = %w[
    a abbr address area article aside audio b bdi bdo blockquote br button canvas caption cite code col colgroup data datalist dd del details dfn dialog div dl dt em
    fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr i iframe img input ins kbd label legend li link main map mark menu meter nav ol optgroup option
    output p picture pre progress q rp rt ruby s samp script search section select slot small source span strong style sub summary sup svg table tbody td template textarea
    tfoot th thead time tr track u ul var video wbr path circle rect line polyline polygon ellipse g defs linearGradient radialGradient stop clipPath
  ].freeze

  ALLOWED_ATTRIBUTES = %w[
    accept accept-charset alt aria-describedby aria-hidden aria-label aria-labelledby aria-live aria-pressed async autocomplete autofocus autoplay checked cite class
    charset cols colspan content contenteditable controls coords crossorigin data-gumroad-action data-gumroad-field datetime defer dir disabled download draggable enctype
    fill for form height hidden href id kind label lang loading loop max maxlength media method min minlength multiple muted name pattern placeholder playsinline poster
    preserveAspectRatio readonly rel required role rows rowspan sandbox scope selected shape size sizes span spellcheck src srcset step style tabindex target title translate type
    value viewBox width xmlns x y x1 y1 x2 y2 cx cy r rx ry d stroke stroke-width stroke-linecap stroke-linejoin fill-rule clip-rule points transform offset stop-color
    stop-opacity
  ].freeze

  URL_ATTRIBUTES = %w[action href poster src xlink:href].freeze
  # Navigating to a URL runs whatever document it resolves to. A `data:` URL
  # in these attributes loads a document with no CSP, so its scripts escape
  # `connect-src 'none'` — block `data:` here outright.
  NAVIGABLE_URL_ATTRIBUTES = %w[action href xlink:href].freeze
  # `src`/`poster` load a resource, not a document. `data:` is fine for inline
  # media (images render without executing embedded SVG script) but not for
  # document MIME types that a browser would parse and script.
  SAFE_DATA_URI_PREFIXES = %w[data:image/ data:video/ data:audio/ data:font/].freeze
  WRAPPER_TAGS = %w[html head body].freeze
  MAX_REPORT_ENTRIES = 100

  Result = Struct.new(:html, :report, keyword_init: true)

  def self.sanitize(html)
    sanitize_with_report(html).html
  end

  def self.sanitize_with_report(html)
    return Result.new(html: "", report: empty_report) if html.blank?

    fragment = Loofah.fragment(html)
    report = empty_report
    scrub_node(fragment, report)
    Result.new(html: fragment.to_html, report: finalize_report(report))
  end

  def self.empty_report
    { removed_tags: [], removed_attributes: [], total_removed: 0, truncated: false }
  end

  def self.finalize_report(report)
    report[:truncated] = report[:total_removed] > (report[:removed_tags].size + report[:removed_attributes].size)
    report
  end

  def self.scrub_node(node, report)
    node.children.to_a.each { |child| scrub_node(child, report) }
    return unless node.element?

    if WRAPPER_TAGS.include?(node.name)
      node.replace(node.children)
      return
    end

    if node.name == "meta" && node["http-equiv"].to_s.casecmp("refresh").zero?
      record_removed_tag(report, node, "meta refresh blocked")
      node.remove
      return
    end

    unless ALLOWED_TAGS.include?(node.name)
      record_removed_tag(report, node, "tag not in allowlist")
      node.remove
      return
    end

    if node.name == "script" && node["src"].present? && !allowed_script_src?(node["src"])
      record_removed_tag(report, node, "script src host not allowed")
      node.remove
      return
    end

    if node.name == "link" && !allowed_stylesheet_link?(node)
      record_removed_tag(report, node, "link must be rel=stylesheet on an allowed host")
      node.remove
      return
    end

    # Overwrite unconditionally — a seller-supplied permissive value
    # (e.g. `allow-same-origin`) should not survive the sanitizer.
    node["sandbox"] = "allow-scripts" if node.name == "iframe"
    if node.name == "form" && node["action"].present?
      record_removed_attribute(report, node, "action", node["action"], "form action removed")
      node.remove_attribute("action")
    end

    # Snapshot with to_a — remove_attribute mutates the node's attribute list,
    # which would skip the next entry if we iterated it live (same reason the
    # children traversal above snapshots).
    node.attribute_nodes.to_a.each do |attribute|
      reason = attribute_removal_reason(attribute.name, attribute.value)
      next unless reason

      record_removed_attribute(report, node, attribute.name, attribute.value, reason)
      node.remove_attribute(attribute.name)
    end
  end

  def self.attribute_removal_reason(name, value)
    return "attribute not in allowlist" unless allowed_attribute?(name)
    return dangerous_url_reason(value) if dangerous_url_attribute?(name, value)

    nil
  end

  def self.record_removed_tag(report, node, reason)
    report[:total_removed] += 1
    return if report_cap_reached?(report)

    report[:removed_tags] << {
      tag: node.name,
      attrs: node.attribute_nodes.to_h { |a| [a.name, strip_control_chars(a.value)] },
      reason: reason
    }
  end

  def self.record_removed_attribute(report, node, name, value, reason)
    report[:total_removed] += 1
    return if report_cap_reached?(report)

    report[:removed_attributes] << {
      tag: node.name,
      attribute: name,
      value: strip_control_chars(value),
      reason: reason
    }
  end

  def self.report_cap_reached?(report)
    report[:removed_tags].size + report[:removed_attributes].size >= MAX_REPORT_ENTRIES
  end

  def self.dangerous_url_reason(value)
    normalize_url(value).start_with?("javascript:") ? "javascript: URL blocked" : "data: URL blocked"
  end

  def self.strip_control_chars(value)
    value.to_s.gsub(/[[:cntrl:]]/, "")
  end

  def self.allowed_attribute?(name)
    name.start_with?("data-", "aria-", "on") || ALLOWED_ATTRIBUTES.include?(name)
  end

  def self.dangerous_url_attribute?(name, value)
    return false unless URL_ATTRIBUTES.include?(name)

    normalized = normalize_url(value)
    return true if normalized.start_with?("javascript:")
    return false unless normalized.start_with?("data:")

    NAVIGABLE_URL_ATTRIBUTES.include?(name) || SAFE_DATA_URI_PREFIXES.none? { |prefix| normalized.start_with?(prefix) }
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

  private_class_method :scrub_node, :allowed_attribute?, :dangerous_url_attribute?, :allowed_script_src?, :allowed_stylesheet_link?, :https_host_in?, :normalize_url, :finalize_report, :record_removed_tag, :record_removed_attribute, :report_cap_reached?, :dangerous_url_reason, :strip_control_chars, :attribute_removal_reason
end
