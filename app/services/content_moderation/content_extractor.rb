# frozen_string_literal: true

require "crass"

class ContentModeration::ContentExtractor
  include SignedUrlHelper
  include Rails.application.routes.url_helpers

  PERMITTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]

  # Storefront pages carry up to Page::MAX_CUSTOM_HTML_LENGTH (500k) characters
  # of seller-authored HTML, so the extracted text is truncated to keep one page
  # save from becoming a very large, very slow model call.
  MAX_PAGE_TEXT_LENGTH = 20_000

  # Link targets get their own slice of the budget, taken before the prose.
  # Concatenating them after the visible text and truncating the result put them
  # at the tail by construction, so a page with 20k characters of benign copy in
  # front of a link farm extracted zero destinations — the one signal a
  # publishing surface's abuse is most likely to be carried by.
  MAX_PAGE_LINK_TEXT_LENGTH = 5_000

  # How many remote images one page may carry and still be moderated. Every image
  # inside this budget IS moderated; a page carrying more is rejected rather than
  # approved on a subset. Sized so the worst case is a handful of batched requests
  # inside one save, far above what a real storefront page uses.
  MAX_PAGE_IMAGE_URLS = 25

  # CSS properties that paint an image the visitor sees. An allowlist rather
  # than every url() in the stylesheet, because url() also appears in values
  # that are not images (fonts, SVG filter references) — sending one to the
  # image moderation endpoint fails, and under full coverage an unmoderated
  # "image" blocks the page. (@font-face is additionally skipped structurally:
  # its declarations sit under an at-rule, not a style rule.)
  IMAGE_CSS_PROPERTIES = %w[
    background background-image border-image border-image-source content cursor
    list-style list-style-image mask mask-border mask-border-source mask-image
  ].freeze

  Result = Struct.new(:text, :image_urls, keyword_init: true)

  def extract_from_product(product)
    description_text = Nokogiri::HTML(product.description.to_s).text
    text = "Name: #{product.name} Description: #{description_text} " + rich_content_text(product.alive_rich_contents)
    text = strip_seller_first_party_urls(text, product.user)
    Result.new(text: text, image_urls: product_image_urls(product))
  end

  def extract_from_post(installment)
    parsed_message = Nokogiri::HTML(installment.message)
    text = "Name: #{installment.name} Message: #{parsed_message.text}"
    text = strip_seller_first_party_urls(text, installment.user)
    image_urls = parsed_message.css("img").filter_map { |img| img["src"] }.reject(&:empty?)
    Result.new(text: text, image_urls: image_urls)
  end

  # A storefront page: either the profile/product custom HTML takeover or a
  # slugged page, carrying rich text `content` or a full `custom_html` document.
  #
  # Link targets come FIRST and carry their own budget: a page is a publishing
  # surface, so the abuse here is usually a set of outbound links (an SEO farm, a
  # redirect to an off-platform storefront) rather than the prose around them,
  # and prose is what a spammer can pad without limit.
  def extract_from_page(page)
    document = page_document(page)

    links = strip_seller_first_party_urls(link_targets(document).join(" "), page.seller)
    prose = strip_seller_first_party_urls("Title: #{page.title} #{document.text}".squish, page.seller)

    # Truncate each part on its own so neither can starve the other, and cut on a
    # whitespace boundary so a bisected word or URL can't manufacture a token the
    # blocklist's word-boundary matching would then match.
    text = "#{truncate_on_boundary(links, MAX_PAGE_LINK_TEXT_LENGTH)} " \
           "#{truncate_on_boundary(prose, MAX_PAGE_TEXT_LENGTH)}".squish

    Result.new(
      text: text,
      # Every image the RENDERED page displays, not a subset: the service rejects a
      # page carrying more than MAX_PAGE_IMAGE_URLS rather than narrowing here, so
      # it needs the real count. Deterministically ordered so a re-save moderates
      # the same images in the same batches.
      #
      # Images come from the sanitized document while the text above comes from the
      # raw one, and the asymmetry is deliberate: text hidden in a tag the
      # sanitizer drops still says something, but an image in one is never
      # displayed, so counting it would reject a page over a limit it does not
      # really reach.
      image_urls: ContentModeration::ImageSelection.ordered(page_image_urls(rendered_document(page)))
    )
  end

  private
    # The page as a document, either representation. Script and style bodies are
    # code, not content, and a page built on a CSS framework carries far more of
    # them than prose — dropping them keeps the moderated text to what a visitor
    # actually reads.
    def page_document(page)
      document = Nokogiri::HTML(page.custom_html.presence || page.content.to_s)
      document.css("script, style, noscript, template").each(&:remove)
      document
    end

    # The page as a visitor receives it. Both preview endpoints and
    # Pages::CustomHtmlWriter assign already-sanitized HTML, so for those this is
    # the same string; the slugged-pages API and the dashboard assign raw input,
    # which `Page#sanitize_html` rewrites in a before_save that has not run yet.
    def rendered_document(page)
      html = if page.custom_html.present?
        Ai::PageSanitizer.sanitize(page.custom_html)
      else
        Pages::RichContentSanitizer.sanitize(page.content)
      end

      document = Nokogiri::HTML(html.to_s)
      # `style` stays, unlike in page_document: a <style> body is not TEXT a
      # visitor reads, but the images it paints do render, and page_image_urls
      # reads them from here.
      document.css("script, noscript, template").each(&:remove)
      document
    end

    # Cut at the last whitespace at or before `max` so a truncation can't leave a
    # half word or half URL behind — the blocklist matches on word boundaries, so
    # a bisected token is a token it can match.
    def truncate_on_boundary(text, max)
      return text if text.length <= max

      cut = text[0, max]
      boundary = cut.rindex(/\s/)
      boundary ? cut[0, boundary] : cut
    end

    # Where a page's links point. Kept as bare URLs so the blocklist's
    # word-boundary matching and the prompt strategies see the destination, and
    # so `strip_seller_first_party_urls` can neutralize the seller's own hosts
    # exactly as it does for a URL written into prose.
    def link_targets(document)
      document.css("a[href]").filter_map do |anchor|
        href = anchor["href"].to_s.strip
        href if remote_url?(href)
      end.uniq
    end

    # Every image the page can DISPLAY, since that is what an approval covers.
    # `img src` is not enough: the sanitizer permits `srcset` (on `img` and
    # `picture > source`), `video poster`, and the `style` attribute and tag —
    # so an image reachable only through one of those, including a CSS
    # `background-image`, renders to every visitor while being reviewed by
    # nothing.
    #
    # Remote URLs the classifier fetches itself; `data:` images are passed through
    # as the base64 payload, which the moderations endpoint accepts in place of a
    # URL, and which is also permitted by the sanitizer and the page CSP. Relative
    # paths have no absolute form here, so they are left out rather than sent as
    # URLs that would 400 the call. Oversized inline payloads are NOT filtered
    # out: ClassifierStrategy refuses them and counts them unmoderated, which
    # blocks the page, where dropping them here would publish it.
    def page_image_urls(document)
      sources = document.css("img[src], video[poster]").flat_map do |node|
        [node["src"], node["poster"]]
      end
      sources += document.css("img[srcset], source[srcset]").flat_map do |node|
        srcset_urls(node["srcset"])
      end
      sources += css_image_urls(document)

      sources.filter_map do |value|
        src = value.to_s.strip
        src if remote_url?(src) || inline_image_url?(src)
      end.uniq
    end

    # URI schemes are case-insensitive and a browser renders `<img src="HTTPS://…">`
    # exactly like the lowercase form, so a case-sensitive predicate here would drop
    # the image from the set that gets moderated while the page still displays it.
    # The original casing is what we return — only the test is normalized.
    def remote_url?(value)
      value.downcase.start_with?("http://", "https://")
    end

    def inline_image_url?(value)
      value.downcase.start_with?("data:image/")
    end

    # `srcset` is a comma-separated candidate list, each entry a URL followed by an
    # optional descriptor. A `data:` URL can itself contain a comma, so entries are
    # split on the comma that precedes a new candidate rather than on every comma.
    def srcset_urls(value)
      value.to_s.split(/,(?=\s*(?:https?:|data:|[^\s,]*\/))/).filter_map do |candidate|
        candidate.strip.split(/\s+/, 2).first.presence
      end
    end

    # Images painted by CSS: `background-image` and friends, in inline `style`
    # attributes and <style> blocks — both survive the sanitizer, and the page
    # CSP's style-src 'unsafe-inline' lets them apply. Parsed with Crass (the
    # tokenizer Loofah itself uses) rather than a regex so comments, escaped
    # identifiers (`\68ttps:`), and semicolons inside data: URLs read here
    # exactly as a browser reads them when it decides what to render.
    def css_image_urls(document)
      document.css("[style]").flat_map { |node| css_declaration_image_urls(Crass.parse_properties(node["style"].to_s)) } +
        document.css("style").flat_map { |node| css_rule_image_urls(Crass.parse(node.text.to_s)) }
    end

    def css_rule_image_urls(rules)
      rules.flat_map do |node|
        next [] unless node.is_a?(Hash)

        case node[:node]
        when :style_rule
          css_declaration_image_urls(node[:children])
        when :at_rule
          # An at-rule's block comes back as raw tokens; re-parsing recovers the
          # rules nested under @media/@supports. @font-face's declarations don't
          # parse as rules and fall out as :error nodes — which is the point:
          # its `src` URLs are fonts, not images.
          node[:block] ? css_rule_image_urls(Crass::Parser.parse_rules(node[:block])) : []
        else
          []
        end
      end
    end

    def css_declaration_image_urls(nodes)
      Array(nodes).flat_map do |node|
        next [] unless node.is_a?(Hash) && node[:node] == :property

        # Custom properties are collected too: `--bg: url(…)` painted via
        # `background-image: var(--bg)` renders like any other background, and
        # var() is not usable in @font-face `src`, so a font can't get in this way.
        name = node[:name].to_s.downcase
        next [] unless name.start_with?("--") || IMAGE_CSS_PROPERTIES.include?(name.sub(/\A-[a-z]+-/, ""))

        css_url_values(node[:children])
      end
    end

    # url() tokens anywhere in the value, including inside functions like
    # image-set() and cross-fade(). Crass has already decoded escapes, so the
    # values compare like the URLs a browser would fetch.
    def css_url_values(nodes)
      Array(nodes).flat_map do |node|
        next [] unless node.is_a?(Hash)

        case node[:node]
        when :url
          [node[:value].to_s]
        when :function
          if node[:name].to_s.downcase == "url"
            Array(node[:value]).filter_map { |token| token[:value].to_s if token.is_a?(Hash) && token[:node] == :string }
          else
            css_url_values(node[:value])
          end
        else
          []
        end
      end
    end

    # A seller linking to their OWN storefront/profile (or one of their own
    # product pages) is inherently first-party and must never be treated as
    # policy-violating content. Domain labels are arbitrary identifiers
    # (usernames, brand names) that can coincidentally contain a blocklisted
    # word as a boundary-delimited token, producing false positives such as a
    # bulk email being rejected for including the seller's own subdomain URL.
    # We neutralize only the scheme+host (the arbitrary domain label) of the
    # seller's own URLs, while PRESERVING any path/query text so user-controlled
    # content in a permalink or query string is still moderated. Third-party
    # URLs are left fully intact so genuine off-site abuse is still caught.
    def strip_seller_first_party_urls(text, seller)
      hosts = seller_first_party_hosts(seller)
      return text if hosts.empty?

      text.gsub(URI::DEFAULT_PARSER.make_regexp(%w[http https])) do |url|
        uri = begin
          URI.parse(url)
        rescue URI::InvalidURIError
          nil
        end
        next url unless uri&.host && hosts.include?(uri.host.downcase)

        # Drop scheme+host (the false-positive domain label); keep path/query/
        # fragment so any blocklisted term the seller put after the host is still
        # seen by the keyword/AI strategies.
        remainder = [uri.path.presence, uri.query.present? ? "?#{uri.query}" : nil,
                     uri.fragment.present? ? "##{uri.fragment}" : nil].compact.join
        remainder.presence || " "
      end
    end

    def seller_first_party_hosts(seller)
      return [] if seller.blank?

      # Only treat a custom domain as first-party when it is ACTIVE (verified +
      # valid cert) — matching UrlService#custom_domain_with_protocol. An alive
      # but unverified custom domain can be an arbitrary off-site URL the seller
      # set without proving ownership, so stripping it would let genuine off-site
      # links bypass moderation.
      custom_domain = seller.custom_domain&.active? ? seller.custom_domain.domain : nil

      [seller.subdomain, custom_domain]
        .compact_blank
        .filter_map { |value| normalize_host(value) }
        .uniq
    end

    # `subdomain` carries a `:port` in dev/test (e.g. "name.test.gumroad.com:31337")
    # while `URI.parse(url).host` never does, so normalize both sides to a bare,
    # port-less, scheme-less hostname before comparing.
    def normalize_host(value)
      URI.parse(value.include?("//") ? value : "//#{value}").host&.downcase
    rescue URI::InvalidURIError
      nil
    end

    def product_image_urls(product)
      # Always use the ORIGINAL file URLs here, never display variants. The
      # default `url` styles trigger synchronous variant generation
      # (`file.variant(...).processed`), and this extractor runs inside the
      # product's save transaction (the content-moderation validation fires
      # during publish). Attaching a freshly generated variant inside a
      # transaction defers its upload to after_commit, by which point the
      # image-processing tempfile has been deleted — the upload then crashes
      # with Errno::ENOENT after the product row has already committed.
      # Moderation only needs the image contents, so the originals are both
      # safe and cheaper.
      cover_image_urls = product.display_asset_previews.joins(file_attachment: :blob)
                                .where(active_storage_blobs: { content_type: PERMITTED_IMAGE_TYPES })
                                .map { |preview| preview.url(style: :original) }

      thumbnail_image_urls = product.thumbnail.present? ? [product.thumbnail.url(variant: :original)] : []

      product_description_image_urls = Nokogiri::HTML(product.link.description).css("img").filter_map { |img| img["src"] }

      rich_contents = product.alive_rich_contents

      rich_content_file_image_urls = rich_contents.flat_map do |rich_content|
        ProductFile.where(id: rich_content.embedded_product_file_ids_in_order, filegroup: "image").filter_map do |product_file|
          signed_download_url_for_s3_key_and_filename(product_file.s3_key, product_file.s3_filename, expires_in: 1.hour)
        rescue Aws::S3::Errors::NotFound
          nil
        end
      end

      rich_content_embedded_image_urls = rich_contents.flat_map do |rich_content|
        rich_content.description.filter_map do |node|
          node.dig("attrs", "src") if node["type"] == "image"
        end
      end.compact

      (cover_image_urls +
        thumbnail_image_urls +
        product_description_image_urls +
        rich_content_file_image_urls +
        rich_content_embedded_image_urls
      ).compact_blank
    end

    def rich_content_text(rich_contents)
      rich_contents.flat_map do |rich_content|
        extract_text(rich_content.description)
      end.join(" ")
    end

    def extract_text(content)
      case content
      when Array
        content.flat_map { |item| extract_text(item) }
      when Hash
        if content["text"]
          Array.wrap(content["text"])
        else
          content.values.flat_map { |value| extract_text(value) }
        end
      else
        []
      end
    end
end
