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

  # For refusal cases the expected outcome is "nothing was ever applied", and a
  # single read would pass simply by running before the message landed. Poll for
  # the whole window instead: a guard that accepts the value applies it within
  # a frame, so any non-empty reading inside this window is a failure.
  def expect_wrapper_never_set(window: 3.0)
    deadline = Time.current + window
    while Time.current < deadline
      expect(wrapper_background).to eq("")
      expect(theme_color).to be_nil
      sleep 0.1
    end
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

  # The reported value is untrusted, and a value that merely PARSES is not
  # enough: `var()` and the CSS-wide keywords parse for any property regardless
  # of what they contain, so the wrapper resolves to a computed color and
  # rejects anything landing on transparent.
  #
  # The page declares NO background of its own, so the hostile message is the
  # only candidate the wrapper ever sees. That is what makes these load-bearing:
  # with a parse-only check the value is accepted and shows up in the canvas and
  # the meta tag, and the polling refusal assertion fails.
  context "when the page reports values that parse but resolve to nothing" do
    ["var(--x)", "var(--x, url(https://evil.example/pixel))", "inherit", "revert"].each do |hostile|
      context "reporting #{hostile}" do
        before do
          seller.update!(custom_html: <<~HTML)
            <main><h1>BG Studio</h1></main>
            <script>
              parent.postMessage({ type: "gumroad:background", color: #{hostile.to_json} }, "*");
            </script>
          HTML
        end

        it "refuses it and applies nothing" do
          visit seller.subdomain_with_protocol
          expect(page).to have_css("iframe#gumroad-landing-frame")

          expect_wrapper_never_set
        end
      end
    end
  end

  # An over-long value is refused before it is ever parsed. Same construction:
  # a syntactically VALID color, so only the length cap can reject it.
  context "when the page reports an absurdly long value" do
    before do
      seller.update!(custom_html: <<~HTML)
        <main><h1>BG Studio</h1></main>
        <script>
          parent.postMessage({ type: "gumroad:background", color: "rgb(1,2,3)" + " ".repeat(5000) }, "*");
        </script>
      HTML
    end

    it "refuses it and applies nothing" do
      visit seller.subdomain_with_protocol
      expect(page).to have_css("iframe#gumroad-landing-frame")

      expect_wrapper_never_set
    end
  end

  # A zero-alpha canvas is the same as no canvas, so html must fall through to
  # body instead of reporting a color that paints nothing. Modern color
  # functions carry alpha after a slash, which an rgb()-only check misses.
  context "when <html> is fully transparent in a modern color function" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html{background:oklch(0.5 0.1 200 / 0)}body{margin:0;background:#EBEBEB}</style>
        <main><h1>BG Studio</h1></main>
      HTML
    end

    it "falls through to the color that actually paints" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")
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

  # Going the other way — a page that drops its background — has to clear the
  # tint too. Reporting only non-empty colors would strand the wrapper on the
  # last opaque theme while the page itself renders transparent.
  context "when the page drops its background after load" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}body.plain{background:transparent}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="drop" type="button">Drop background</button>
        </main>
        <script>
          document.getElementById("drop").addEventListener("click", function () {
            document.body.classList.add("plain");
          });
        </script>
      HTML
    end

    it "clears the wrapper canvas and removes the theme-color tag" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")
      expect(theme_color).to eq("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Drop background" }

      expect_wrapper_background("")
      expect(theme_color).to be_nil
    end
  end

  # A clear and a REFUSAL are different messages, and only the comment in
  # custom_html_background_wrapper_script said so — flipping `if (!color)
  # return` to also clear left every other example green. That would hand a
  # child the power to strip its own theme by posting junk.
  context "when a hostile value arrives after a legitimate color" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="attack" type="button">Send junk</button>
        </main>
        <script>
          document.getElementById("attack").addEventListener("click", function () {
            parent.postMessage({ type: "gumroad:background", color: "var(--nope)" }, "*");
            parent.postMessage({ type: "gumroad:background", color: 12345 }, "*");
          });
        </script>
      HTML
    end

    it "keeps the color already applied" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Send junk" }

      # Poll the whole window: a wrongly-clearing guard blanks the canvas within
      # a frame of the message, so a single read could pass before it lands.
      deadline = Time.current + 2.0
      while Time.current < deadline
        expect(wrapper_background).to eq("rgb(235, 235, 235)")
        expect(theme_color).to eq("rgb(235, 235, 235)")
        sleep 0.1
      end
    end
  end
end
