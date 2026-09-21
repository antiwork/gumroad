# frozen_string_literal: true

# A new profile page does not fit in one tool call, and publishing a partial page replaces the
# storefront. Sections accumulate here until propose_profile_page turns the composed document
# into the existing confirmation card. Nothing in this store is live.
class Ai::ProfilePageDraft
  TTL_SECONDS = 7.days.to_i
  MAX_SECTIONS = 24
  MAX_SECTION_HTML = 12_000
  CATALOGUE_KINDS = %w[name_bio products posts].freeze
  KINDS = (CATALOGUE_KINDS + %w[html]).freeze

  Result = Struct.new(:tell_the_creator, :error, :section_count, keyword_init: true) do
    def success? = error.nil?
  end

  def initialize(seller:, conversation: nil)
    @seller = seller
    @conversation = conversation
  end

  def empty? = sections.empty?

  def section_count = sections.size

  def sections
    @sections ||= load_sections
  end

  def seed_catalogue!
    CATALOGUE_KINDS.each do |kind|
      next if sections.any? { |section| section["kind"] == kind }

      sections << { "kind" => kind, "label" => default_label(kind) }
    end
    save!
    self
  end

  def clear!
    @sections = []
    save!
    Result.new(tell_the_creator: seller_update(:cleared), section_count: 0)
  end

  def append(kind:, html: nil, label: nil, heading: nil)
    kind = kind.to_s
    return Result.new(error: "kind must be one of: #{KINDS.join(', ')}.") unless KINDS.include?(kind)

    if kind == "html"
      fragment = sanitize_fragment(html)
      return fragment if fragment.is_a?(Result)

      label = label.to_s.strip.presence || "Section"
      sections.reject! { |section| section["kind"] == "html" && section["label"] == label }
      return Result.new(error: "The draft already has #{MAX_SECTIONS} sections. Say preview, or clear a section first.") if sections.size >= MAX_SECTIONS

      sections << { "kind" => "html", "label" => label, "html" => fragment }
    else
      return Result.new(error: "A #{kind} section is filled by the server. Do not send html for it.") if html.present?

      sections.reject! { |section| section["kind"] == kind }
      entry = { "kind" => kind, "label" => label.to_s.strip.presence || default_label(kind) }
      entry["heading"] = heading.to_s.strip if heading.to_s.strip.present?
      sections << entry
    end

    save!
    Result.new(tell_the_creator: seller_update(:added, label: sections.last["label"]), section_count: sections.size)
  end

  def compose
    body = [DOCUMENT_STYLE, *sections.map { |section| render_section(section) }].join("\n")
    Ai::PageSanitizer.sanitize(body).presence || body
  end

  def seller_update(event, label: nil)
    count = sections.size
    case event
    when :added
      %(Added "#{plain(label)}" to your page draft (#{count} #{'section'.pluralize(count)}). Nothing is published. Tell me the next section, or say preview when you want the confirmation card.)
    when :cleared
      "Cleared the page draft. Nothing was published."
    when :seeded_after_truncation
      "A whole profile page doesn't fit in one reply, and publishing part of one would replace your storefront, so I didn't publish anything. I added your name, bio, and live product and post lists to a draft (#{count} sections). Nothing is live. Tell me the next section, or say preview when you want the confirmation card."
    when :section_did_not_fit
      "That section was too big for one reply, so I didn't add it. Your draft still has #{count} #{'section'.pluralize(count)} and nothing is published. Send a smaller section, or say preview when you want the confirmation card."
    end
  end

  private
    def load_sections
      raw = $redis.get(redis_key)
      return [] if raw.blank?

      parsed = JSON.parse(raw)
      parsed.is_a?(Array) ? parsed.select { |section| section.is_a?(Hash) } : []
    rescue JSON::ParserError
      []
    end

    def save!
      if sections.empty?
        $redis.del(redis_key)
      else
        $redis.set(redis_key, JSON.generate(sections), ex: TTL_SECONDS)
      end
    end

    def redis_key
      RedisKey.profile_page_draft(@seller.id, @conversation&.id)
    end

    def sanitize_fragment(html)
      return Result.new(error: "html is required for a custom section.") if html.blank?
      return Result.new(error: "That section is over #{MAX_SECTION_HTML} characters. Split it and send the next piece.") if html.to_s.length > MAX_SECTION_HTML

      sanitized = Ai::PageSanitizer.sanitize(html).to_s.strip
      return Result.new(error: "That section was removed by the page sanitizer. Send different HTML.") if sanitized.blank?

      sanitized
    end

    def render_section(section)
      case section["kind"]
      when "name_bio" then NAME_BIO_HTML
      when "products" then catalogue_section("products", section["heading"].presence || "Products", "No products yet", "products")
      when "posts" then catalogue_section("posts", section["heading"].presence || "Posts", "No posts yet", "posts")
      else section["html"].to_s
      end
    end

    def catalogue_section(grid, heading, empty_copy, key)
      <<~HTML
        <section data-profile-section="#{grid}">
          <h2>#{ERB::Util.h(heading)}</h2>
          <p data-profile-count="#{grid}"></p>
          <ul class="#{grid}" data-profile-grid="#{grid}"></ul>
          <script>
            (function () {
              var dataEl = document.getElementById("gumroad-data");
              if (!dataEl) return;
              var data;
              try { data = JSON.parse(dataEl.textContent); } catch (e) { return; }
              var items = data.#{key} || [];
              var total = data.#{key}_total || items.length;
              var count = document.querySelector('[data-profile-count="#{grid}"]');
              if (count && total > items.length) count.textContent = "Showing " + items.length + " of " + total + " #{grid}";
              var list = document.querySelector('[data-profile-grid="#{grid}"]');
              if (!list) return;
              function appendItem(item) {
                var li = document.createElement("li");
                var link = document.createElement("a");
                link.href = item.url || "#";
                var thumb = item.thumbnail_url || item.cover_url;
                if (thumb) {
                  var img = document.createElement("img");
                  img.alt = "";
                  img.src = thumb;
                  link.appendChild(img);
                }
                var details = document.createElement("div");
                details.className = "details";
                var title = document.createElement("h3");
                title.textContent = item.name || "";
                details.appendChild(title);
                if (#{key.to_json} === "products") {
                  var price = document.createElement("span");
                  price.className = "price";
                  var permalink = String(item.url || "").split("/").filter(Boolean).pop() || "";
                  price.setAttribute("data-gumroad-product", permalink);
                  price.setAttribute("data-gumroad-field", "price");
                  details.appendChild(price);
                }
                link.appendChild(details);
                li.appendChild(link);
                list.appendChild(li);
              }
              if (!items.length) {
                var empty = document.createElement("p");
                empty.textContent = #{empty_copy.to_json};
                list.parentNode.insertBefore(empty, list);
                return;
              }
              items.forEach(function (item) { appendItem(item); });
              if (#{key.to_json} === "products" && total > items.length && window.gumroadProducts) {
                var more = document.createElement("button");
                more.type = "button";
                more.textContent = "Load more";
                more.addEventListener("click", function () {
                  more.disabled = true;
                  window.gumroadProducts.request({ offset: list.children.length, limit: 100 }).then(function (page) {
                    (page.products || []).forEach(function (item) { appendItem(item); });
                    if (count && page.productsTotal > list.children.length) {
                      count.textContent = "Showing " + list.children.length + " of " + page.productsTotal + " products";
                    } else if (count) {
                      count.textContent = "";
                    }
                    if (!page.productsTotal || list.children.length >= page.productsTotal || !(page.products || []).length) {
                      more.remove();
                    } else {
                      more.disabled = false;
                    }
                  });
                });
                list.parentNode.appendChild(more);
              }
            })();
          </script>
        </section>
      HTML
    end

    def default_label(kind)
      { "name_bio" => "Name and bio", "products" => "Products", "posts" => "Posts" }.fetch(kind)
    end

    def plain(text)
      text.to_s.gsub(/[\r\n\t]+/, " ").strip.truncate(80)
    end

    NAME_BIO_HTML = <<~HTML.freeze
      <header class="creator">
        <h1 data-gumroad-field="name">Store</h1>
      </header>
      <p class="bio" data-gumroad-field="bio"></p>
    HTML

    DOCUMENT_STYLE = <<~HTML.freeze
      <style>
        * { box-sizing: border-box; }
        body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; color: #000; line-height: 1.5; }
        main, .profile-draft { max-width: 64rem; margin: 0 auto; padding: 3rem 1.5rem; }
        header.creator h1 { margin: 0 0 1rem; font-size: 2rem; line-height: 1.2; }
        p.bio { margin: 0 0 2rem; max-width: 42rem; }
        section h2 { font-size: 1.25rem; margin: 2.5rem 0 1rem; }
        .products { display: grid; grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr)); gap: 1rem; padding: 0; margin: 0; list-style: none; }
        .products a { display: block; color: inherit; text-decoration: none; border: 1px solid #000; border-radius: 8px; overflow: hidden; }
        .products img { display: block; width: 100%; aspect-ratio: 1; object-fit: cover; }
        .products .details { padding: 0.75rem 1rem; }
        .posts { padding: 0; margin: 0; list-style: none; }
        .posts a { display: block; padding: 0.75rem 0; color: inherit; }
      </style>
    HTML
end
