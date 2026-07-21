# frozen_string_literal: true

require "spec_helper"
require "zip"

describe "EPUB reader", type: :system, js: true do
  let(:buyer) { create(:user) }
  let(:product) { create(:product, name: "Browser EPUB") }
  let(:epub) do
    create(
      :epub_product_file,
      link: product,
      url: "#{S3_BASE_URL}specs/browser-reader-#{SecureRandom.hex}.epub"
    )
  end
  let(:purchase) { create(:free_purchase, link: product, purchaser: buyer, email: buyer.email) }
  let(:url_redirect) { create(:url_redirect, link: product, purchase:) }

  before do
    epub_object.put(body: fixture_epub, content_type: "application/epub+zip")
    login_as buyer

    page.driver.browser.execute_cdp(
      "Page.addScriptToEvaluateOnNewDocument",
      source: <<~JS
        window.__epubBlobUrls = { created: [], revoked: [] };
        const createObjectURL = URL.createObjectURL.bind(URL);
        const revokeObjectURL = URL.revokeObjectURL.bind(URL);
        URL.createObjectURL = (value) => {
          const url = createObjectURL(value);
          window.__epubBlobUrls.created.push(url);
          return url;
        };
        URL.revokeObjectURL = (url) => {
          window.__epubBlobUrls.revoked.push(url);
          return revokeObjectURL(url);
        };
      JS
    )
  end

  after do
    epub_object.delete
  end

  it "loads packaged styles, applies themes, strips remote resources, and releases blobs" do
    visit url_redirect_read_for_product_file_path(url_redirect.token, epub.external_id)

    expect(page).to have_css("iframe", wait: 30)
    within_frame(find("iframe")) do
      expect(page).to have_css("#chapter-title", text: "Styled EPUB")
      expect(page.evaluate_script("getComputedStyle(document.querySelector('#chapter-title')).fontSize")).to eq("31px")
      expect(page.evaluate_script("document.querySelector('#remote-image').hasAttribute('src')")).to be(false)
    end

    click_on "Appearance"
    find("[role='radio'][aria-label='Dark']").click
    within_frame(find("iframe")) do
      expect(page).to have_css("body.dark")
      expect(page.evaluate_script("getComputedStyle(document.body).backgroundColor")).to eq("rgb(18, 18, 18)")
    end

    created_urls = page.evaluate_script("window.__epubBlobUrls.created")
    expect(created_urls).not_to be_empty

    page.execute_script("window.dispatchEvent(new PageTransitionEvent('pagehide'))")
    revoked_urls = page.evaluate_script("window.__epubBlobUrls.revoked")
    expect(revoked_urls).to include(*created_urls)
  end

  def epub_object
    @epub_object ||= Aws::S3::Resource.new.bucket(S3_BUCKET).object(epub.s3_key)
  end

  def fixture_epub
    Zip::OutputStream.write_buffer do |archive|
      archive.put_next_entry("mimetype", nil, nil, Zip::Entry::STORED)
      archive.write("application/epub+zip")
      archive.put_next_entry("META-INF/container.xml")
      archive.write(<<~XML)
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
      XML
      archive.put_next_entry("content.opf")
      archive.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="2.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">browser-reader-fixture</dc:identifier>
            <dc:title>Browser reader fixture</dc:title>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="styles" href="styles.css" media-type="text/css"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="chapter"/></spine>
        </package>
      XML
      archive.put_next_entry("toc.ncx")
      archive.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">
          <head><meta name="dtb:uid" content="browser-reader-fixture"/></head>
          <docTitle><text>Browser reader fixture</text></docTitle>
          <navMap><navPoint id="chapter"><navLabel><text>Chapter</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap>
        </ncx>
      XML
      archive.put_next_entry("styles.css")
      archive.write("#chapter-title { font-size: 31px; }")
      archive.put_next_entry("chapter.xhtml")
      archive.write(<<~HTML)
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Chapter</title><link rel="stylesheet" href="styles.css"/></head>
          <body>
            <h1 id="chapter-title">Styled EPUB</h1>
            <img id="remote-image" src="https://epub-remote-resource.invalid/pixel.png" alt=""/>
            <p>This chapter verifies the real epub.js iframe path.</p>
          </body>
        </html>
      HTML
    end.string
  end
end
