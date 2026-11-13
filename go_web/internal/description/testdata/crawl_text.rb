# frozen_string_literal: true

# Writes crawl_text.json.gz: the product page crawl fallback's description
# (LinksController#set_product_page_crawl_fallback) for every html_safe_description in
# descriptions.json.gz, and for hand-written cases.
#   ruby crawl_text.rb | gzip -9 -n > crawl_text.json.gz
require "json"
require "zlib"
gem "loofah", "2.25.1"
gem "nokogiri", "1.19.3"
gem "actionview", "8.1.3.1"
require "loofah"
require "action_view"

class Formatter
  include ActionView::Helpers::TextHelper
end

corpus = JSON.parse(Zlib::GzipReader.open(File.join(__dir__, "descriptions.json.gz"), &:read))
hand = [
  "", " ", "plain", "a & b < c", "&lt;/noscript&gt;", "<p>one</p><p>two</p>", "<p>one<br>two<br><br>three</p>",
  "<div><div><p>deep</p></div></div>", "<ul><li>a</li><li>b</li></ul>", "<ol>\n<li>x</li>\n\n\n<li>y</li>\n</ol>",
  "<h1>Title</h1>text<hr>more", "<pre>line 1\n  line 2\n\n\n\nline 3</pre>", "<blockquote>q</blockquote>tail",
  "<p>a</p>\n\n\n\n<p>b</p>", "<p> </p><p>x</p>", "<p>x\v</p>\n\v\n<p>y</p>", "a\r\nb\r\n\r\nc", " lead and trail ",
  "<script>alert(1)</script>after", "<p>before<iframe src=\"https://www.youtube.com/embed/x\"></iframe>after</p>",
  "<upsell-card productid=\"x\"></upsell-card>text", "<public-file-embed id=\"x\"></public-file-embed><p>p</p>",
  "<review-card reviewid=\"x\"></review-card>", "<!-- note --><p>visible</p>", "<figure><img src=\"x.png\"><figcaption>cap</figcaption></figure>",
  "<a href=\"https://example.com\">link</a> and <strong>bold</strong> <em>it</em>", "<p>it's \"quoted\"</p>",
  "<table><tr><td>a</td><td>b</td></tr></table>", "<span>in</span><span>line</span>", "<p>   </p>\n\n<p>  </p>", "<br>",
  "<br><br><br>x", "x<br>", "<code>a\n\n\nb</code>"
]
htmls = (corpus["cases"].filter_map { _1["html"] } + hand).uniq
cases = htmls.map do |html|
  text = Loofah.fragment(html).scrub!(:prune).to_text(encode_special_chars: false).strip
  { html:, text:, formatted: Formatter.new.simple_format(ERB::Util.html_escape(text), {}, sanitize: false) }
end
puts JSON.generate(cases)
