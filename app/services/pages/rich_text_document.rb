# frozen_string_literal: true

# Renders a rich text page (Page#content) into the standalone HTML document
# the public page serves. Shared by:
#
# - UserPagesController#show — the actual public render at /<slug>
# - Api::V2::PagesController#show (`rendered_html`) — the eject path: when an
#   agent takes over a rich text page with custom HTML, it starts from this
#   faithful render of the current page instead of reverse-engineering the
#   layout from raw rich text.
class Pages::RichTextDocument
  # head_extra: canonical/OG meta tags (request-dependent, so callers build it).
  # profile_href: where the header byline links; "/" on custom domains.
  def self.render(page:, seller_name:, profile_href: "/", head_extra: "")
    title = ERB::Util.h(page.title.to_s)
    seller = ERB::Util.h(seller_name.to_s)
    href = ERB::Util.h(profile_href)
    <<~HTML.html_safe
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{title} — #{seller}</title>
          #{head_extra}
          <style>
            :root { color-scheme: light dark; }
            body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; background: #fff; color: #000; }
            main { max-width: 42rem; margin: 0 auto; padding: 3rem 1.5rem; }
            header a { font-size: 0.875rem; color: inherit; }
            h1.page-title { margin: 0.5rem 0 2rem; font-size: 2rem; line-height: 1.2; }
            article img { max-width: 100%; height: auto; }
            article pre { overflow-x: auto; padding: 1rem; background: rgba(127, 127, 127, 0.1); border-radius: 4px; }
            article blockquote { margin: 1rem 0; padding-left: 1rem; border-left: 3px solid currentColor; opacity: 0.8; }
            article table { border-collapse: collapse; }
            article th, article td { border: 1px solid rgba(127, 127, 127, 0.4); padding: 0.4rem 0.6rem; }
            @media (prefers-color-scheme: dark) { body { background: #000; color: #fff; } }
          </style>
        </head>
        <body>
          <main>
            <header>
              <a href="#{href}">#{seller}</a>
              <h1 class="page-title">#{title}</h1>
            </header>
            <article>#{page.content}</article>
          </main>
        </body>
      </html>
    HTML
  end
end
