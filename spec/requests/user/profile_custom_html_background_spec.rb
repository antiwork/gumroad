# frozen_string_literal: true

require "spec_helper"

# A custom-HTML page renders inside a sandboxed, opaque-origin iframe, so the
# seller's CSS reaches only the document INSIDE the frame. The wrapper around
# it stays transparent and paints white wherever the iframe doesn't cover:
# iOS Safari's status-bar/toolbar strips, and the overscroll gutter everywhere
# else. The seller cannot fix it themselves — Ai::PageSanitizer strips <meta>,
# so a theme-color tag never survives (gumroad-private#1530).
#
# The gumroad:background bridge closes that gap: the sandboxed page reports its
# own computed canvas color, and the trusted wrapper mirrors it onto the
# wrapper canvas plus a theme-color meta tag. These specs drive it in a real
# browser, because the value only exists after the browser has computed styles.
describe "Profile custom HTML page background bridge", type: :system, js: true do
  let(:seller) { create(:user, username: "bgstudio", name: "BG Studio") }

  def wrapper_background
    page.evaluate_script("document.documentElement.style.backgroundColor")
  end

  # The color arrives over postMessage after the browser has computed styles,
  # so every assertion on it has to poll rather than read once.
  def expect_wrapper_background(color)
    wait_until_true(sleep_interval: 0.1) { wrapper_background == color }
    expect(wrapper_background).to eq(color)
  end

  def theme_color
    page.evaluate_script(<<~JS)
      (function () {
        var m = document.querySelector('meta[name="theme-color"]');
        return m ? m.getAttribute("content") : null;
      })();
    JS
  end

  before { Feature.activate_user(:custom_html_pages, seller) }

  context "when the page sets its background on <body>" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main><h1>BG Studio</h1></main>
      HTML
    end

    it "mirrors the color onto the wrapper canvas and a theme-color tag" do
      visit seller.subdomain_with_protocol

      expect(page).to have_css("iframe#gumroad-landing-frame")
      # Waits for the postMessage round trip rather than asserting immediately.
      expect_wrapper_background("rgb(235, 235, 235)")
      expect(theme_color).to eq("rgb(235, 235, 235)")
    end
  end

  # CSS only propagates body's background to the canvas when html has none of
  # its own. A page that sets both must report html's color, or the bands would
  # be tinted with a color the visitor never sees.
  context "when the page sets a background on both <html> and <body>" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html{background:#102030}body{margin:0;background:#EBEBEB}</style>
        <main><h1>BG Studio</h1></main>
      HTML
    end

    it "reports the color that actually paints the canvas" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(16, 32, 48)")
    end
  end

  # A page that declares nothing leaves both elements transparent. Writing that
  # through would be a no-op at best, so the bridge stays silent and the
  # wrapper keeps its default rendering.
  context "when the page declares no background" do
    before do
      seller.update!(custom_html: "<main><h1>BG Studio</h1></main>")
    end

    it "leaves the wrapper untouched" do
      visit seller.subdomain_with_protocol

      expect(page).to have_css("iframe#gumroad-landing-frame")
      within_frame(find("iframe#gumroad-landing-frame")) do
        expect(page).to have_text("BG Studio")
      end

      expect(wrapper_background).to eq("")
      expect(theme_color).to be_nil
    end
  end

  # The reported color is seller-influenced, so the wrapper never writes it
  # into HTML: it round-trips through the CSS parser and only a value the
  # browser normalizes back out is applied. Anything unparseable is dropped.
  context "when the page reports a hostile value" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main><h1>BG Studio</h1></main>
        <script>
          parent.postMessage({ type: "gumroad:background", color: 'red;"><img src=x onerror=alert(1)>' }, "*");
        </script>
      HTML
    end

    it "ignores it and keeps the legitimately computed color" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")
      expect(theme_color).to eq("rgb(235, 235, 235)")
      expect(page).to have_no_css("img[src='x']")
    end
  end

  # Theme toggles re-color the page after load. Reporting only once would
  # strand the bands on the first theme the visitor saw.
  context "when the page changes its background after load" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}body.dark{background:#101010}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="toggle" type="button">Toggle theme</button>
        </main>
        <script>
          document.getElementById("toggle").addEventListener("click", function () {
            document.body.classList.add("dark");
          });
        </script>
      HTML
    end

    it "re-reports the new color to the wrapper" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Toggle theme" }

      expect_wrapper_background("rgb(16, 16, 16)")
      expect(theme_color).to eq("rgb(16, 16, 16)")
    end
  end
end
