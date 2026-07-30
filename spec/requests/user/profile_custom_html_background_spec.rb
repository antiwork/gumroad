# frozen_string_literal: true

require "spec_helper"

# The bridge mirrors the opaque-origin iframe's computed canvas color onto its
# trusted wrapper and theme-color metadata. These specs need a real browser
# because the value exists only after style computation.
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

  # These parse as colors but do not resolve to opaque paint. With no legitimate
  # page background, any wrapper color proves the guard accepted the report.
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

  [
    ["on <body>", "html,body{margin:0}body{background:rgba(0,0,0,.5)}"],
    ["on <html> above an opaque <body>", "html{background:rgba(0,0,0,.5)}body{margin:0;background:#EBEBEB}"],
  ].each do |placement, styles|
    context "when the page canvas is translucent #{placement}" do
      before do
        seller.update!(custom_html: <<~HTML)
          <style>#{styles}</style>
          <main><h1>BG Studio</h1></main>
        HTML
      end

      it "leaves the wrapper untouched instead of compositing the color twice" do
        visit seller.subdomain_with_protocol
        expect(page).to have_css("iframe#gumroad-landing-frame")

        expect_wrapper_never_set
      end
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

  # A retheme can bypass the DOM entirely: editing a rule through
  # `sheet.cssRules`, `insertRule`, `replaceSync` on an adopted sheet, or
  # flipping `sheet.disabled` all repaint the canvas while the document tree
  # stays byte-for-byte identical. There is no mutation to observe and no load
  # event to catch, so the observer cannot cover any of these — a periodic
  # re-read is the only thing that can. Each shape below is its own example
  # because they fail independently: a fix that only handled `insertRule` would
  # leave the adopted-sheet case stale.
  #
  # The re-read is also what makes these load-bearing rather than incidental —
  # removing the interval leaves every one of them stranded on the first color.
  {
    "editing a rule through cssRules" => <<~JS,
      var sheet = document.getElementById("theme").sheet;
      sheet.cssRules[sheet.cssRules.length - 1].style.backgroundColor = "#101010";
    JS
    "inserting a rule through insertRule" => <<~JS,
      var sheet = document.getElementById("theme").sheet;
      sheet.insertRule("body{background:#101010}", sheet.cssRules.length);
    JS
    "adopting a constructed stylesheet" => <<~JS,
      var sheet = new CSSStyleSheet();
      sheet.replaceSync("body{background:#101010}");
      document.adoptedStyleSheets = [sheet];
    JS
  }.each do |description, mutation|
    context "when the page changes its background by #{description}" do
      before do
        seller.update!(custom_html: <<~HTML)
          <style id="theme">html,body{margin:0}body{background:#EBEBEB}</style>
          <main>
            <h1>BG Studio</h1>
            <button id="retheme" type="button">Retheme</button>
          </main>
          <script>
            document.getElementById("retheme").addEventListener("click", function () {
              #{mutation}
            });
          </script>
        HTML
      end

      it "re-reports the new color to the wrapper" do
        visit seller.subdomain_with_protocol

        expect_wrapper_background("rgb(235, 235, 235)")

        within_frame(find("iframe#gumroad-landing-frame")) { click_on "Retheme" }

        expect_wrapper_background("rgb(16, 16, 16)")
        expect(theme_color).to eq("rgb(16, 16, 16)")
      end
    end
  end

  # Disabling a sheet is the shape with no DOM write at all — not even an
  # attribute, since `sheet.disabled` lives on the CSSOM object and leaves the
  # <style> element's attributes untouched. The element is inserted up front so
  # its insertion is not the mutation under test.
  context "when the page changes its background by disabling a stylesheet" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <style id="dark">body{background:#101010}</style>
        <main>
          <h1>BG Studio</h1>
          <button id="light" type="button">Light</button>
          <button id="dark-on" type="button">Dark</button>
        </main>
        <script>
          var sheet = document.getElementById("dark").sheet;
          sheet.disabled = true;
          document.getElementById("light").addEventListener("click", function () {
            sheet.disabled = true;
          });
          document.getElementById("dark-on").addEventListener("click", function () {
            sheet.disabled = false;
          });
        </script>
      HTML
    end

    it "re-reports in both directions" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Dark" }
      expect_wrapper_background("rgb(16, 16, 16)")
      expect(theme_color).to eq("rgb(16, 16, 16)")

      within_frame(find("iframe#gumroad-landing-frame")) { click_on "Light" }
      expect_wrapper_background("rgb(235, 235, 235)")
      expect(theme_color).to eq("rgb(235, 235, 235)")
    end
  end

  # The re-read fires on a timer, so it could report the same unchanged color
  # over and over — a postMessage per second per open page, forever. `report`
  # returns early on an unchanged value, and this is what holds it to that: the
  # wrapper is instrumented to count what actually arrives across several
  # intervals of a page that never changes.
  context "when nothing about the page changes" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main><h1>BG Studio</h1></main>
      HTML
    end

    it "does not re-post the color it already reported" do
      visit seller.subdomain_with_protocol

      expect_wrapper_background("rgb(235, 235, 235)")

      page.execute_script(<<~JS)
        window.__bgMessages = 0;
        window.addEventListener("message", function (e) {
          var d = e.data;
          if (d && typeof d === "object" && d.type === "gumroad:background") window.__bgMessages++;
        });
      JS

      sleep(RendersCustomHtmlPages::BACKGROUND_POLL_INTERVAL_MS / 1000.0 * 4)

      expect(page.evaluate_script("window.__bgMessages")).to eq(0)
      expect(wrapper_background).to eq("rgb(235, 235, 235)")
    end
  end

  describe "the canvas opacity check" do
    let(:opaque_colors) do
      [
        "rgb(0, 0, 0)",
        "rgb(235, 235, 235)",
        "rgba(18, 52, 86, 1)",
        "rgba(18, 52, 86, 100%)",
        "color(srgb 0 0 0)",
        "oklch(0.5 0.1 200 / 1)",
        "oklch(0.5 0.1 200)",
        "black",
      ]
    end

    let(:unpaintable_colors) do
      [
        "transparent",
        "",
        "rgba(0, 0, 0, 0)",
        "rgba(18, 52, 86, 0.5)",
        "rgba(18, 52, 86, 50%)",
        "oklch(0.5 0.1 200 / 0)",
        "oklch(0.5 0.1 200 / 0.5)",
        "color(srgb 0 0 0 / 0)",
        "light-dark(rgb(0,0,0), rgb(255,255,255))",
      ]
    end

    def opaque?(color)
      page.evaluate_script(<<~JS)
        (function () {
          #{RendersCustomHtmlPages::CANVAS_OPAQUE_FN}
          return opaque(#{color.to_json});
        })();
      JS
    end

    before do
      seller.update!(custom_html: "<main><h1>BG Studio</h1></main>")
      visit seller.subdomain_with_protocol
    end

    it "treats a solid color as paintable" do
      expect(opaque_colors.reject { opaque?(_1) }).to eq([])
    end

    it "refuses a color it cannot read as fully opaque" do
      expect(unpaintable_colors.select { opaque?(_1) }).to eq([])
    end
  end
end
