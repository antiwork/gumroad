# frozen_string_literal: true

# Renders the seller's DEFAULT storefront (the profile home page as it looks
# before any custom HTML takeover) into a single standalone HTML document.
#
# This is the "pull" starting point for going custom on the profile: instead of
# starting an agent from a blank file, `GET /v2/user/custom_html` returns this
# render (as `rendered_html`) so the agent begins from a faithful snapshot of
# what the profile already shows — creator header, product grid, recent posts —
# then edits and pushes the result back.
# Slugged pages get the same treatment from Pages::RichTextDocument; this
# service is the profile-root counterpart.
#
# Deliberately NOT included: links to the seller's slugged pages. The default
# storefront doesn't render those links anywhere, and a seller may rely on a
# page being unlinked (a hidden discount page, a draft shared privately). Adding
# them here would mean a pull-then-push publishes navigation the current
# storefront never showed. Agents that want a pages nav can list pages via the
# API and add links intentionally.
#
# It deliberately reuses Pages::ProfileData (the same cached snapshot injected
# into published custom pages as `gumroad-data`), so the pulled document and
# the data an agent later reads at runtime agree with each other. All URLs are
# absolute (products use Link#long_url on the seller's subdomain) because the
# document is destined to be served inside the sandboxed custom-HTML iframe,
# where relative links wouldn't reach the seller's store.
class Pages::DefaultProfileDocument
  def self.render(seller)
    profile = SellerProfile.find_by(seller_id: seller.id)
    # The colors land inside a <style> block, where HTML-escaping isn't the
    # right defense (it leaves CSS metacharacters like ; { } intact). The model
    # validates these as hex colors, but its regex uses line anchors (^ $),
    # which a multiline value can slip past — so re-check the whole string here
    # (\A \z) and fall back to the defaults for anything that isn't exactly a
    # hex color. Nothing seller-controlled can then reach the <style> block.
    background = css_hex_color(profile&.background_color, default: "#ffffff")
    highlight = css_hex_color(profile&.highlight_color, default: "#ff90e8")
    name = ERB::Util.h(seller.name_or_username.to_s)
    bio = ERB::Util.h(seller.bio.to_s)
    avatar = ERB::Util.h(seller.avatar_url.to_s)
    data = Pages::ProfileData.build(seller)

    <<~HTML
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{name}</title>
          <style>
            :root { --background: #{background}; --accent: #{highlight}; }
            * { box-sizing: border-box; }
            body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: var(--background); color: #000; line-height: 1.5; }
            main { max-width: 64rem; margin: 0 auto; padding: 3rem 1.5rem; }
            header.creator { display: flex; align-items: center; gap: 1rem; margin-bottom: 1rem; }
            header.creator img { width: 4rem; height: 4rem; border-radius: 50%; border: 1px solid #000; }
            header.creator h1 { margin: 0; font-size: 2rem; line-height: 1.2; }
            p.bio { margin: 0 0 2rem; max-width: 42rem; }
            section h2 { font-size: 1.25rem; margin: 2.5rem 0 1rem; }
            .products { display: grid; grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr)); gap: 1rem; padding: 0; margin: 0; list-style: none; }
            .products a { display: block; height: 100%; color: inherit; text-decoration: none; border: 1px solid #000; border-radius: 8px; overflow: hidden; background: #fff; }
            .products a:hover { box-shadow: 4px 4px 0 var(--accent); }
            .products img { display: block; width: 100%; aspect-ratio: 1; object-fit: cover; border-bottom: 1px solid #000; }
            .products .details { padding: 0.75rem 1rem; }
            .products h3 { margin: 0 0 0.5rem; font-size: 1rem; }
            .products .price { display: inline-block; padding: 0.125rem 0.5rem; border: 1px solid #000; border-radius: 4px; background: var(--accent); font-size: 0.875rem; }
            .posts { padding: 0; margin: 0; list-style: none; }
            .posts li { border-top: 1px solid rgba(0, 0, 0, 0.2); }
            .posts a { display: block; padding: 0.75rem 0; color: inherit; }
          </style>
        </head>
        <body>
          <main>
            <header class="creator">
              #{avatar.present? ? %(<img src="#{avatar}" alt="#{name}">) : ""}
              <h1>#{name}</h1>
            </header>
            #{bio.present? ? %(<p class="bio">#{bio}</p>) : ""}
            #{products_section(data[:products])}
            #{posts_section(data[:posts])}
          </main>
        </body>
      </html>
    HTML
  end

  def self.products_section(products)
    return "" if products.blank?

    items = products.map do |product|
      thumbnail = product[:thumbnail_url].present? ? %(<img src="#{ERB::Util.h(product[:thumbnail_url])}" alt="">) : ""
      <<~ITEM
        <li>
          <a href="#{ERB::Util.h(product[:url])}">
            #{thumbnail}
            <div class="details">
              <h3>#{ERB::Util.h(product[:name])}</h3>
              <span class="price">#{ERB::Util.h(product[:price])}</span>
            </div>
          </a>
        </li>
      ITEM
    end
    %(<section><h2>Products</h2><ul class="products">#{items.join("\n")}</ul></section>)
  end

  def self.posts_section(posts)
    return "" if posts.blank?

    items = posts.map do |post|
      %(<li><a href="#{ERB::Util.h(post[:url])}">#{ERB::Util.h(post[:name])}</a></li>)
    end
    %(<section><h2>Posts</h2><ul class="posts">#{items.join("\n")}</ul></section>)
  end

  # Strict whole-string hex color check (#rrggbb) for values interpolated into
  # the <style> block. Anything else falls back to the given default.
  def self.css_hex_color(value, default:)
    value.to_s.match?(/\A#[0-9a-f]{6}\z/i) ? value : default
  end
end
