# frozen_string_literal: true

require "spec_helper"

describe "Profile custom HTML page background bridge", type: :system, js: true do
  let(:seller) { create(:user, username: "bgstudio", name: "BG Studio") }

  def wrapper_background
    page.evaluate_script("document.documentElement.style.backgroundColor")
  end

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

  # Poll refusal cases long enough for a wrongly accepted report to arrive.
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

  context "when <html> has a background image over a transparent color" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html{background:linear-gradient(#123,#456)}body{margin:0;background:#EBEBEB}</style>
        <main><h1>BG Studio</h1></main>
      HTML
    end

    it "does not mistake the body's color for the canvas" do
      visit seller.subdomain_with_protocol
      expect(page).to have_css("iframe#gumroad-landing-frame")
      expect_wrapper_never_set
    end
  end

  context "when <html> composites an opaque color through opacity" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html{background:#000;opacity:.5}body{margin:0}</style>
        <main><h1>BG Studio</h1></main>
      HTML
    end

    it "does not paint the color underneath and composite it twice" do
      visit seller.subdomain_with_protocol
      expect(page).to have_css("iframe#gumroad-landing-frame")
      expect_wrapper_never_set
    end
  end

  [
    ["<html>", "html{display:none;background:#000}"],
    ["<body>", "body{display:none;background:#000}"],
  ].each do |element, styles|
    context "when #{element} has a color but does not render" do
      before do
        seller.update!(custom_html: "<style>html,body{margin:0}#{styles}</style><main><h1>BG Studio</h1></main>")
      end

      it "does not paint the hidden color onto the wrapper" do
        visit seller.subdomain_with_protocol
        expect(page).to have_css("iframe#gumroad-landing-frame")
        expect_wrapper_never_set
      end
    end
  end

  [
    ["<html>", "html{visibility:hidden;background:#000}"],
    ["<body>", "body{visibility:hidden;background:#000}"],
  ].each do |element, styles|
    context "when #{element} hides its contents but still paints a background" do
      before do
        seller.update!(custom_html: "<style>html,body{margin:0}#{styles}</style><main><h1>BG Studio</h1></main>")
      end

      it "mirrors the canvas color" do
        visit seller.subdomain_with_protocol
        expect_wrapper_background("rgb(0, 0, 0)")
      end
    end
  end

  [
    ["<html>", "html{contain:paint}body{background:#000}"],
    ["<body>", "body{contain:paint;background:#000}"],
  ].each do |element, styles|
    context "when #{element} contains the body's background paint" do
      before do
        seller.update!(custom_html: "<style>html,body{margin:0}#{styles}</style><main><h1>BG Studio</h1></main>")
      end

      it "does not extend the body color across the wrapper canvas" do
        visit seller.subdomain_with_protocol
        expect(page).to have_css("iframe#gumroad-landing-frame")
        expect_wrapper_never_set
      end
    end
  end

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

  context "when a transparent page requests a dark color scheme" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html{color-scheme:dark}html,body{margin:0}</style>
        <main><h1>BG Studio</h1></main>
      HTML
    end

    it "mirrors the browser's opaque iframe backplate" do
      visit seller.subdomain_with_protocol
      canvas = within_frame(find("iframe#gumroad-landing-frame")) do
        page.evaluate_script(<<~JS)
          (function () {
            var probe = document.createElement("span");
            probe.style.backgroundColor = "Canvas";
            document.body.appendChild(probe);
            return getComputedStyle(probe).backgroundColor;
          })();
        JS
      end
      expect_wrapper_background(canvas)
      expect(theme_color).to eq(canvas)
    end
  end

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

  context "when the iframe loads another document" do
    before do
      seller.update!(custom_html: <<~HTML)
        <style>html,body{margin:0}body{background:#EBEBEB}</style>
        <main><h1>Opaque page</h1></main>
      HTML
    end

    {
      "a transparent bridged page" => ["<main><h1>Transparent page</h1></main>", "Transparent page", nil],
      "another opaque bridged page" => [
        "<style>body{background:#101010}</style><main><h1>Dark page</h1></main>",
        "Dark page",
        "rgb(16, 16, 16)",
      ],
    }.each do |destination, (html, text, color)|
      it "resets for #{destination}" do
        visit seller.subdomain_with_protocol
        expect_wrapper_background("rgb(235, 235, 235)")
        seller.update!(custom_html: html)
        page.execute_script(<<~JS)
          var frame = document.getElementById("gumroad-landing-frame");
          frame.src = frame.src.split("?")[0] + "?reloaded";
        JS
        within_frame(find("iframe#gumroad-landing-frame")) { expect(page).to have_text(text) }
        expect_wrapper_background(color || "")
        expect(theme_color).to eq(color)
      end
    end

    it "clears for a destination without the bridge" do
      visit seller.subdomain_with_protocol
      expect_wrapper_background("rgb(235, 235, 235)")
      page.execute_script(<<~JS)
        window.__landingLoaded = false;
        var frame = document.getElementById("gumroad-landing-frame");
        frame.addEventListener("load", function () { window.__landingLoaded = true; }, { once: true });
        frame.src = "about:blank";
      JS
      wait_until_true(sleep_interval: 0.1) { page.evaluate_script("window.__landingLoaded") }
      expect_wrapper_background("")
      expect(theme_color).to be_nil
    end
  end

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

  context "when the page changes its background by loading an external stylesheet" do
    let(:stylesheet_path) { Rails.root.join("public", "spec-late-theme.css") }

    before do
      File.write(stylesheet_path, "body{background:#101010}")
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

  context "when the page changes its background by inserting a nested external stylesheet" do
    let(:stylesheet_path) { Rails.root.join("public", "spec-nested-late-theme.css") }

    before do
      File.write(stylesheet_path, "body{background:#101010}")
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
