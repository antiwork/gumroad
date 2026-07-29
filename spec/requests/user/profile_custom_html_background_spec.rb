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
  # The zero-alpha rows are here for a different reason: they resolve to a
  # perfectly real color that simply paints nothing. `getComputedStyle` echoes
  # modern color functions back in their own syntax rather than normalizing to
  # rgba(), so a wrapper-local check that only understood `rgba(…)` accepted
  # `oklch(… / 0)` and painted a transparent canvas — while the child, which
  # locates alpha by token, refused the same value. Both halves share one
  # implementation now, and these rows fail if that sharing is undone.
  #
  # The page declares NO background of its own, so the hostile message is the
  # only candidate the wrapper ever sees. That is what makes these load-bearing:
  # with a parse-only check the value is accepted and shows up in the canvas and
  # the meta tag, and the polling refusal assertion fails.
  context "when the page reports values that parse but resolve to nothing" do
    [
      "var(--x)",
      "var(--x, url(https://evil.example/pixel))",
      "inherit",
      "revert",
      "oklch(0.7 0.1 200 / 0)",
      "lab(50 40 30 / 0)",
      "color(display-p3 0.5 0.2 0.9 / 0)",
      "oklab(0.5 0.1 0.1 / 0)",
    ].each do |hostile|
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

  # Every existing example uses a color with a non-zero last channel, so the
  # alpha check could read a trailing channel as alpha and the file stayed
  # green. Black is the case that matters most in practice — it is what a dark
  # theme sets, and it is exactly the value a positional check mistakes for
  # transparent.
  context "when the page's background is a color whose last channel is zero" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#000}</style>
        <main><h1>BG Studio</h1></main>
      HTML
    end

    it "reports it instead of treating the trailing zero as transparency" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(0, 0, 0)")
      expect(theme_color).to eq("rgb(0, 0, 0)")
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

  # Not every theme toggle touches an attribute. Rewriting a <style>'s text or
  # inserting a new one repaints the canvas with html and body untouched, so an
  # attribute-only observer sees nothing and the bands keep the old theme.
  context "when the page changes its background by rewriting a stylesheet" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style id="theme">html,body{margin:0}body{background:#EBEBEB}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="rewrite" type="button">Rewrite theme</button>
        </main>
        <script>
          document.getElementById("rewrite").addEventListener("click", function () {
            document.getElementById("theme").textContent = "html,body{margin:0}body{background:#101010}";
          });
        </script>
      HTML
    end

    it "re-reports the new color to the wrapper" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Rewrite theme" }

      expect_wrapper_background("rgb(16, 16, 16)")
      expect(theme_color).to eq("rgb(16, 16, 16)")
    end
  end

  # The seller's HTML renders inside <body>, so a stylesheet they add later goes
  # in there too — appending to <head> would land BEFORE their own style and lose
  # the cascade, leaving the canvas unchanged and proving nothing.
  context "when the page changes its background by inserting a stylesheet" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="insert" type="button">Add theme</button>
        </main>
        <script>
          document.getElementById("insert").addEventListener("click", function () {
            var style = document.createElement("style");
            style.textContent = "body{background:#101010}";
            document.body.appendChild(style);
          });
        </script>
      HTML
    end

    it "re-reports the new color to the wrapper" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Add theme" }

      expect_wrapper_background("rgb(16, 16, 16)")
      expect(theme_color).to eq("rgb(16, 16, 16)")
    end
  end

  # An inserted <link> repaints the canvas only once its stylesheet has loaded,
  # which is strictly after the mutation that inserted it — so the report that
  # mutation queues still reads the OLD color. Nothing observes the DOM again,
  # so without a load listener on the element itself this is the one retheme
  # route that reports a color the page no longer has. A window-level listener
  # does not cover it: a resource's load event never reaches the window, in
  # either phase.
  context "when the page changes its background by loading an external stylesheet" do
    let(:stylesheet_path) { Rails.root.join("public", "spec-late-theme.css") }

    before do
      File.write(stylesheet_path, "body{background:#101010}")
      # Same-origin would be simplest, but this document's CSP has no 'self' in
      # style-src, so the sheet has to come from the allowed asset host.
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="load" type="button">Load theme</button>
        </main>
        <script>
          document.getElementById("load").addEventListener("click", function () {
            var link = document.createElement("link");
            link.rel = "stylesheet";
            link.href = "#{PROTOCOL}://#{ASSET_DOMAIN}/spec-late-theme.css";
            document.body.appendChild(link);
          });
        </script>
      HTML
    end

    after { FileUtils.rm_f(stylesheet_path) }

    it "re-reports the new color once the stylesheet has loaded" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Load theme" }

      expect_wrapper_background("rgb(16, 16, 16)")
      expect(theme_color).to eq("rgb(16, 16, 16)")
    end
  end

  # A mutation record names only the node that moved. Templating a chunk of
  # markup in — innerHTML, a cloned <template>, a framework mount — hands the
  # observer one container element, and the stylesheet that repaints the canvas
  # rides inside it. Checking the container alone sees an ordinary <div>.
  context "when the page changes its background by inserting a nested stylesheet" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="insert" type="button">Add theme</button>
        </main>
        <script>
          document.getElementById("insert").addEventListener("click", function () {
            var wrapper = document.createElement("div");
            wrapper.innerHTML = "<section><style>body{background:#101010}</style></section>";
            document.body.appendChild(wrapper);
          });
        </script>
      HTML
    end

    it "re-reports the new color to the wrapper" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Add theme" }

      expect_wrapper_background("rgb(16, 16, 16)")
      expect(theme_color).to eq("rgb(16, 16, 16)")
    end
  end

  # The nested case compounds with the late-load one: the container's insertion
  # is the only mutation, and the sheet it carries applies after it. So the
  # descendant walk has to hand that <link> its load listener too, or the one
  # report this ever queues reads the pre-stylesheet color.
  context "when the page changes its background by inserting a nested external stylesheet" do
    let(:stylesheet_path) { Rails.root.join("public", "spec-nested-late-theme.css") }

    before do
      File.write(stylesheet_path, "body{background:#101010}")
      # Same-origin would be simplest, but this document's CSP has no 'self' in
      # style-src, so the sheet has to come from the allowed asset host.
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="load" type="button">Load theme</button>
        </main>
        <script>
          document.getElementById("load").addEventListener("click", function () {
            var wrapper = document.createElement("div");
            var section = document.createElement("section");
            var link = document.createElement("link");
            link.rel = "stylesheet";
            link.href = "#{PROTOCOL}://#{ASSET_DOMAIN}/spec-nested-late-theme.css";
            section.appendChild(link);
            wrapper.appendChild(section);
            document.body.appendChild(wrapper);
          });
        </script>
      HTML
    end

    after { FileUtils.rm_f(stylesheet_path) }

    it "re-reports the new color once the nested stylesheet has loaded" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Load theme" }

      expect_wrapper_background("rgb(16, 16, 16)")
      expect(theme_color).to eq("rgb(16, 16, 16)")
    end
  end
end
