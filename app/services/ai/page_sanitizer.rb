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
    tfoot th thead time tr track u ul var video wbr path circle rect line polyline polygon ellipse g defs lineargradient radialgradient stop clippath
  ].freeze

  ALLOWED_ATTRIBUTES = %w[
    accept accept-charset alt aria-describedby aria-hidden aria-label aria-labelledby aria-live aria-pressed async autocomplete autofocus autoplay checked cite class
    charset cols colspan content contenteditable controls coords crossorigin datetime defer dir disabled download draggable enctype
    fill for form height hidden href id kind label lang loading loop max maxlength media method min minlength multiple muted name pattern placeholder playsinline poster
    preserveaspectratio readonly rel required role rows rowspan sandbox scope selected shape size sizes span spellcheck src srcset step style tabindex target title translate type
    value viewbox width xmlns x y x1 y1 x2 y2 cx cy r rx ry d stroke stroke-width stroke-linecap stroke-linejoin fill-rule clip-rule clip-path points transform offset stop-color
    stop-opacity
  ].freeze

  URL_ATTRIBUTES = %w[action href poster src].freeze
  SRCSET_ATTRIBUTES = %w[srcset].freeze
  # Navigating to a URL runs whatever document it resolves to. A `data:` URL
  # in these attributes loads a document with no CSP, so its scripts escape
  # `connect-src 'none'` — block `data:` here outright.
  NAVIGABLE_URL_ATTRIBUTES = %w[action href].freeze
  DOCUMENT_SOURCE_TAGS = %w[iframe].freeze
  # Media `src`/`poster` attributes load a resource, not a document. `data:` is
  # fine for inline media but not for document MIME types that a browser would parse and script.
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

    unless allowed_tag?(node.name)
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
      reason = attribute_removal_reason(node.name, attribute.name, attribute.value)
      next unless reason

      record_removed_attribute(report, node, attribute.name, attribute.value, reason)
      node.remove_attribute(attribute.name)
    end
  end

  def self.attribute_removal_reason(tag_name, name, value)
    return "attribute not in allowlist" unless allowed_attribute?(name)
    return unsafe_target_reason(value) if name.downcase == "target"
    return "data: URL blocked" if document_source_data_url?(tag_name, name, value)
    return srcset_url_removal_reason(value) if SRCSET_ATTRIBUTES.include?(name.downcase)
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
    normalized_name = name.downcase
    normalized_name.start_with?("data-", "aria-") || event_handler_attribute?(normalized_name) || ALLOWED_ATTRIBUTES.include?(normalized_name)
  end

  def self.allowed_tag?(name)
    ALLOWED_TAGS.include?(name.downcase)
  end

  def self.event_handler_attribute?(name)
    name.match?(/\Aon[a-z][a-z0-9]*\z/)
  end

  def self.dangerous_url_attribute?(name, value)
    normalized_name = name.downcase
    return false unless URL_ATTRIBUTES.include?(normalized_name)

    normalized = normalize_url(value)
    return true if normalized.start_with?("javascript:")
    return false unless normalized.start_with?("data:")

    NAVIGABLE_URL_ATTRIBUTES.include?(normalized_name) || SAFE_DATA_URI_PREFIXES.none? { |prefix| normalized.start_with?(prefix) }
  end

  def self.document_source_data_url?(tag_name, name, value)
    DOCUMENT_SOURCE_TAGS.include?(tag_name.downcase) &&
      name.downcase == "src" &&
      normalize_url(value).start_with?("data:")
  end

  def self.srcset_url_removal_reason(value)
    normalized_urls = srcset_urls(value).map { |url| normalize_url(url) }
    return "javascript: URL blocked" if normalized_urls.any? { |url| url.start_with?("javascript:") }
    return "data: URL blocked" if normalized_urls.any? { |url| url.start_with?("data:") && SAFE_DATA_URI_PREFIXES.none? { |prefix| url.start_with?(prefix) } }

    nil
  end

  def self.srcset_urls(value)
    value.to_s.split(/\s*,\s*/).filter_map do |candidate|
      url = candidate.strip.split(/\s+/, 2).first
      url if url.present?
    end
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
    uri.scheme == "https" && hosts.include?(uri.host&.downcase)
  rescue URI::InvalidURIError
    false
  end

  def self.unsafe_target_reason(value)
    %w[_parent _top _unfencedtop].include?(value.to_s.strip.downcase) ? "target navigation blocked" : nil
  end

  def self.normalize_url(value)
    decoded = CGI.unescapeHTML(value.to_s)
    10.times do
      next_decoded = Addressable::URI.unencode_component(decoded)
      break if next_decoded == decoded

      decoded = next_decoded
    rescue Addressable::URI::InvalidURIError
      break
    end
    decoded.gsub(/[[:space:]\u0000-\u001f]+/, "").downcase
  end

  private_class_method :scrub_node, :allowed_tag?, :allowed_attribute?, :event_handler_attribute?, :dangerous_url_attribute?, :document_source_data_url?, :srcset_url_removal_reason, :srcset_urls, :allowed_script_src?, :allowed_stylesheet_link?, :https_host_in?, :unsafe_target_reason, :normalize_url, :finalize_report, :record_removed_tag, :record_removed_attribute, :report_cap_reached?, :dangerous_url_reason, :strip_control_chars, :attribute_removal_reason
end
