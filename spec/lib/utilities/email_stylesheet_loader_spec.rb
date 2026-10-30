# frozen_string_literal: true

require "spec_helper"

describe EmailStylesheetLoader, :skip_ssrf_stub do
  let(:public_ip) { "93.184.216.34" }
  let(:private_ip) { "10.0.0.5" }
  let(:seller_css) { ".seller-note { color: #0a7d3e; }" }

  before do
    allow(Resolv).to receive(:getaddresses).and_wrap_original do |original, host|
      # Literal addresses and nil (which Resolv rejects with ArgumentError) never reach the network.
      raise "unstubbed DNS lookup for #{host}" unless host.nil? || host.match?(Resolv::AddressRegex)

      original.call(host)
    end
    allow(Resolv).to receive(:getaddresses).with("cdn.example.com").and_return([public_ip])
    allow(Resolv).to receive(:getaddresses).with("internal.example.net").and_return([private_ip])
  end

  # Every unsafe target is stubbed too, so a regression shows up as a request having been made
  # rather than as a real connection attempt.
  def stub_unsafe(url)
    stub_request(:get, url).to_return(status: 200, body: ".leaked { color: red; }")
  end

  def with_env(vars)
    previous = vars.keys.index_with { ENV[_1] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  describe "own assets" do
    it "reads the built email stylesheet from disk without any HTTP request" do
      path = Dir[Rails.root.join("public", ViteRuby.config.public_output_dir, "assets", "entrypoints", "email-*.css")].first
      href = path.delete_prefix(Rails.public_path.to_s)

      expect(SsrfFilter).not_to receive(:get)
      css = described_class.load(href)
      expect(css).to include("--font-family:")
      expect(css).not_to include("@layer")
    end

    it "keeps the built stylesheet's custom properties through premailer" do
      path = Dir[Rails.root.join("public", ViteRuby.config.public_output_dir, "assets", "entrypoints", "email-*.css")].first
      html = Premailer.new("<html><body><p>Hi</p></body></html>", with_html_string: true, css_string: described_class.load(path.delete_prefix(Rails.public_path.to_s))).to_inline_css

      expect(Nokogiri::HTML(html).at("html")["style"]).to include("--font-family:", "--color:", "--body-bg:")
    end

    it "does not read files outside public/" do
      stub_request(:get, %r{\Ahttps://cdn\.example\.com/}).to_return(status: 200, body: seller_css)

      expect(described_class.load("/../Gemfile")).to eq("")
      expect(described_class.load("https://cdn.example.com/../Gemfile")).to eq(seller_css)
    end

    context "when the asset host is the local development server" do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
        allow(Rails.configuration.action_controller).to receive(:asset_host).and_return("http://assets.example.org:3000")
      end

      it "fetches the email's own CSS from it with timeouts, since SsrfFilter refuses loopback" do
        own_css = stub_request(:get, "http://assets.example.org:3000/vite-dev/entrypoints/email.scss").to_return(status: 200, body: "body { margin: 0; }")
        expect(SsrfFilter).not_to receive(:get)
        expect(Net::HTTP).to receive(:start).with("assets.example.org", 3000, hash_including(open_timeout: 3, read_timeout: 5)).and_call_original

        expect(described_class.load("/vite-dev/entrypoints/email.scss")).to eq("body { margin: 0; }")
        expect(own_css).to have_been_requested
      end

      it "also fetches from the mailer asset host, which mailer views link to" do
        allow(Rails.configuration.action_mailer).to receive(:asset_host).and_return("http://mailer.example.org:3000")
        own_css = stub_request(:get, "http://mailer.example.org:3000/vite-dev/entrypoints/email.scss").to_return(status: 200, body: "body { margin: 0; }")
        expect(SsrfFilter).not_to receive(:get)

        expect(described_class.load("http://mailer.example.org:3000/vite-dev/entrypoints/email.scss")).to eq("body { margin: 0; }")
        expect(own_css).to have_been_requested
      end

      it "sends another port on the same host through SsrfFilter" do
        allow(Resolv).to receive(:getaddresses).with("assets.example.org").and_return([public_ip])
        other_port = stub_unsafe("http://assets.example.org:6379/x.css")

        expect(described_class.load("http://assets.example.org:6379/x.css")).to eq("")
        expect(other_port).not_to have_been_requested
      end

      it "keeps the built email CSS but drops a response larger than the limit, declared or streamed" do
        built = File.read(Dir[Rails.root.join("public", ViteRuby.config.public_output_dir, "assets", "entrypoints", "email-*.css")].first)
        stub_request(:get, "http://assets.example.org:3000/vite-dev/entrypoints/email.css").to_return(status: 200, body: built)
        stub_request(:get, "http://assets.example.org:3000/big.css").to_return(status: 200, body: "a" * (EmailStylesheetLoader::MAX_BYTES + 1))
        stub_request(:get, "http://assets.example.org:3000/declared.css").to_return(status: 200, body: "body { margin: 0; }", headers: { "Content-Length" => (EmailStylesheetLoader::MAX_BYTES + 1).to_s })

        expect(described_class.load("/vite-dev/entrypoints/email.css")).to include("--font-family:")
        expect(described_class.load("/big.css")).to eq("")
        expect(described_class.load("/declared.css")).to eq("")
      end

      it "drops a response that outlasts the whole-fetch deadline" do
        stub_const("EmailStylesheetLoader::FETCH_TIMEOUT_SECONDS", 0.1)
        stub_request(:get, "http://assets.example.org:3000/slow.css").to_return(->(_request) { sleep 2; { status: 200, body: "body { margin: 0; }" } })

        expect(described_class.load("/slow.css")).to eq("")
      end

      it "shares the email's deadline across its local stylesheets" do
        stub_const("EmailStylesheetLoader::FETCH_TIMEOUT_SECONDS", 0.2)
        stub_const("EmailStylesheetLoader::DOCUMENT_TIMEOUT_SECONDS", 0.3)
        slow = (1..3).map do |n|
          stub_request(:get, "http://assets.example.org:3000/#{n}.css").to_return(->(_request) { sleep 2; { status: 200, body: "body { margin: 0; }" } })
        end
        links = (1..3).map { %(<link rel="stylesheet" href="/#{_1}.css">) }.join

        expect(Premailer::Rails::CSSHelper.css_for_doc(Nokogiri::HTML("<html><head>#{links}</head><body></body></html>"))).to eq("\n\n")
        expect(slow.first).to have_been_requested
        expect(slow.last).not_to have_been_requested
      end
    end

    it "sends the asset host through SsrfFilter outside development" do
      allow(Rails.configuration.action_controller).to receive(:asset_host).and_return("https://assets.example.org")
      allow(Resolv).to receive(:getaddresses).with("assets.example.org").and_return(["127.0.0.1"])
      asset_host = stub_unsafe("https://assets.example.org/x.css")

      expect(described_class.load("/x.css")).to eq("")
      expect(asset_host).not_to have_been_requested
    end
  end

  describe "seller stylesheets" do
    it "fetches a public stylesheet, connecting to the address it validated" do
      stub_request(:get, "https://cdn.example.com/seller.css").with(headers: { "Accept" => "text/css" }).to_return(status: 200, body: seller_css)
      expect(Net::HTTP).to receive(:start)
        .with("cdn.example.com", 443, hash_including(ipaddr: public_ip, open_timeout: 3, read_timeout: 5))
        .and_call_original

      expect(described_class.load("https://cdn.example.com/seller.css")).to eq(seller_css)
      expect(Resolv).to have_received(:getaddresses).with("cdn.example.com").once
    end

    it "treats a protocol-relative href as http" do
      stub_request(:get, "http://cdn.example.com/seller.css").to_return(status: 200, body: seller_css)

      expect(described_class.load("//cdn.example.com/seller.css")).to eq(seller_css)
    end

    it "returns the stylesheet as UTF-8 so it joins with the email's own CSS" do
      stub_request(:get, "https://cdn.example.com/seller.css").to_return(status: 200, body: %(.note::before { content: "→"; }).b)

      css = described_class.load("https://cdn.example.com/seller.css")

      expect(css.encoding).to eq(Encoding::UTF_8)
      expect(css).to include("→")
    end

    it "follows redirects within the limit" do
      stub_request(:get, "https://cdn.example.com/a.css").to_return(status: 301, headers: { "Location" => "https://cdn.example.com/b.css" })
      stub_request(:get, "https://cdn.example.com/b.css").to_return(status: 302, headers: { "Location" => "/c.css" })
      stub_request(:get, "https://cdn.example.com/c.css").to_return(status: 200, body: seller_css)

      expect(described_class.load("https://cdn.example.com/a.css")).to eq(seller_css)
    end

    [
      "http://10.0.0.5/x.css",
      "http://169.254.169.254/latest/meta-data/",
      "http://127.0.0.1/x.css",
      "http://[::1]/x.css",
      "http://100.64.0.1/x.css",
      "http://internal.example.net/x.css",
    ].each do |url|
      it "drops #{url} without requesting it" do
        unsafe = stub_unsafe(url)

        expect(described_class.load(url)).to eq("")
        expect(unsafe).not_to have_been_requested
      end
    end

    ["http://cdn.example.com:81/x.css", "https://cdn.example.com:8443/x.css", "http://cdn.example.com:443/x.css"].each do |url|
      it "drops #{url} because of its port" do
        unsafe = stub_unsafe(url)

        expect(described_class.load(url)).to eq("")
        expect(unsafe).not_to have_been_requested
      end
    end

    it "drops a non-http scheme" do
      expect(SsrfFilter).to receive(:get).and_call_original

      expect(described_class.load("ftp://cdn.example.com/x.css")).to eq("")
    end

    {
      "a private address" => "http://internal.example.net/x.css",
      "a link-local address" => "http://169.254.169.254/latest/meta-data/",
      "a disallowed port" => "http://cdn.example.com:6379/x.css",
    }.each do |target, location|
      it "drops a redirect to #{target} without requesting it" do
        stub_request(:get, "https://cdn.example.com/seller.css").to_return(status: 302, headers: { "Location" => location })
        unsafe = stub_unsafe(location)

        expect(described_class.load("https://cdn.example.com/seller.css")).to eq("")
        expect(unsafe).not_to have_been_requested
      end
    end

    it "drops a redirect to a non-http scheme" do
      stub_request(:get, "https://cdn.example.com/seller.css").to_return(status: 302, headers: { "Location" => "file:///etc/passwd" })

      expect(described_class.load("https://cdn.example.com/seller.css")).to eq("")
    end

    it "drops a redirect to a URL with no host" do
      stub_request(:get, "https://cdn.example.com/seller.css").to_return(status: 302, headers: { "Location" => "http:/x.css" })

      expect(described_class.load("https://cdn.example.com/seller.css")).to eq("")
    end

    it "re-resolves the host on each redirect hop, so a rebound record cannot reach a private address" do
      allow(Resolv).to receive(:getaddresses).with("cdn.example.com").and_return([public_ip], [private_ip])
      stub_request(:get, "https://cdn.example.com/seller.css").to_return(status: 302, headers: { "Location" => "/next.css" })
      rebound = stub_unsafe("https://cdn.example.com/next.css")
      expect(Net::HTTP).to receive(:start).once.with("cdn.example.com", 443, hash_including(ipaddr: public_ip)).and_call_original

      expect(described_class.load("https://cdn.example.com/seller.css")).to eq("")
      expect(rebound).not_to have_been_requested
    end

    it "drops the stylesheet past the redirect limit" do
      (1..4).each do |hop|
        stub_request(:get, "https://cdn.example.com/#{hop}.css").to_return(status: 302, headers: { "Location" => "/#{hop + 1}.css" })
      end
      past_limit = stub_request(:get, "https://cdn.example.com/5.css").to_return(status: 200, body: seller_css)

      expect(described_class.load("https://cdn.example.com/1.css")).to eq("")
      expect(a_request(:get, "https://cdn.example.com/4.css")).to have_been_made
      expect(past_limit).not_to have_been_requested
    end

    it "drops the stylesheet on a timeout" do
      stub_request(:get, "https://cdn.example.com/seller.css").to_timeout

      expect(described_class.load("https://cdn.example.com/seller.css")).to eq("")
    end

    it "drops the stylesheet when the whole fetch outlasts its deadline, even before the headers arrive" do
      stub_const("EmailStylesheetLoader::FETCH_TIMEOUT_SECONDS", 0.1)
      stub_request(:get, "https://cdn.example.com/seller.css").to_return(->(_request) { sleep 2; { status: 200, body: seller_css } })

      expect(described_class.load("https://cdn.example.com/seller.css")).to eq("")
    end

    it "ignores a proxy from the environment, which would resolve the host itself" do
      stub_request(:get, "https://cdn.example.com/seller.css").to_return(status: 200, body: seller_css)
      connections = []
      allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **options, &block|
        original.call(*args, **options) do |http|
          connections << { proxy: http.proxy?, ipaddr: options[:ipaddr] }
          block.call(http)
        end
      end

      with_env("http_proxy" => "http://proxy.example.net:3128", "no_proxy" => nil, "NO_PROXY" => nil) do
        expect(Net::HTTP.new("cdn.example.com", 443).proxy?).to be(true)
        expect(described_class.load("https://cdn.example.com/seller.css")).to eq(seller_css)
      end
      expect(connections).to eq([{ proxy: false, ipaddr: public_ip }])
    end

    it "drops an error response" do
      stub_request(:get, "https://cdn.example.com/seller.css").to_return(status: 404, body: "<html>Not found</html>")

      expect(described_class.load("https://cdn.example.com/seller.css")).to eq("")
    end

    it "drops a response larger than the limit" do
      stub_request(:get, "https://cdn.example.com/big.css").to_return(status: 200, body: "a" * (EmailStylesheetLoader::MAX_BYTES + 1))
      stub_request(:get, "https://cdn.example.com/declared.css").to_return(status: 200, body: seller_css, headers: { "Content-Length" => (EmailStylesheetLoader::MAX_BYTES + 1).to_s })

      expect(described_class.load("https://cdn.example.com/big.css")).to eq("")
      expect(described_class.load("https://cdn.example.com/declared.css")).to eq("")
    end

    it "drops a response with a malformed Content-Length" do
      stub_request(:get, "https://cdn.example.com/seller.css").to_return(status: 200, body: seller_css, headers: { "Content-Length" => "abc" })
      # WebMock's read_body skips the Content-Length parsing Net::HTTP's real read_body starts with.
      allow_any_instance_of(Net::HTTP).to receive(:request).and_wrap_original do |original, request, &block|
        original.call(request) do |response|
          response.define_singleton_method(:read_body) { |*| content_length }
          block.call(response)
        end
      end

      expect(described_class.load("https://cdn.example.com/seller.css")).to eq("")
    end

    it "drops a host that does not resolve" do
      allow(Resolv).to receive(:getaddresses).with("missing.example.com").and_return([])

      expect(described_class.load("https://missing.example.com/seller.css")).to eq("")
    end

    ["http://exa mple.com/x.css", "http://[::1/x.css", "/missing.css", "mailto:a@example.com", "javascript:x", "http:foo"].each do |href|
      it "drops #{href.inspect}" do
        expect(described_class.load(href)).to eq("")
      end
    end
  end

  describe "cascade layers" do
    let(:layered) do
      <<~CSS
        @layer base, theme;
        @layer base {
          :root { --font-family: Avenir; }
          @media (min-width: 640px) { p { margin: 0; } }
          a::after { content: "}"; }
        }
        /* @layer theme { */
        p { color: red; }
      CSS
    end

    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
      allow(Rails.configuration.action_controller).to receive(:asset_host).and_return("http://assets.example.org:3000")
    end

    it "unwraps our own layer blocks and drops layer statements, leaving strings and comments intact" do
      stub_request(:get, "http://assets.example.org:3000/layered.css").to_return(status: 200, body: layered)

      expect(described_class.load("/layered.css")).to eq(
        "\n\n" \
        "  :root { --font-family: Avenir; }\n" \
        "  @media (min-width: 640px) { p { margin: 0; } }\n" \
        "  a::after { content: \"}\"; }\n" \
        "\n" \
        "/* @layer theme { */\n" \
        "p { color: red; }\n"
      )
    end

    it "leaves a seller's layers alone, so its unlayered rules keep their priority" do
      stub_request(:get, "https://cdn.example.com/layered.css").to_return(status: 200, body: layered)

      expect(described_class.load("https://cdn.example.com/layered.css")).to eq(layered)
    end

    it "scans unterminated headers, strings, and comments once" do
      broken = "@layer " * 50_000 + "/*" * 50_000
      stub_request(:get, "http://assets.example.org:3000/broken.css").to_return(status: 200, body: broken)

      expect(Timeout.timeout(5) { described_class.load("/broken.css") }).to eq(broken)
    end
  end

  describe "a whole email" do
    it "shares one deadline across every remote stylesheet in the document" do
      stub_const("EmailStylesheetLoader::FETCH_TIMEOUT_SECONDS", 0.2)
      stub_const("EmailStylesheetLoader::DOCUMENT_TIMEOUT_SECONDS", 0.3)
      slow = (1..3).map do |n|
        stub_request(:get, "https://cdn.example.com/#{n}.css").to_return(->(_request) { sleep 2; { status: 200, body: seller_css } })
      end
      links = (1..3).map { %(<link rel="stylesheet" href="https://cdn.example.com/#{_1}.css">) }.join
      doc = Nokogiri::HTML("<html><head>#{links}</head><body></body></html>")

      expect(Premailer::Rails::CSSHelper.css_for_doc(doc)).to eq("\n\n")
      expect(slow.first).to have_been_requested
      expect(slow.last).not_to have_been_requested
      expect(Thread.current[EmailStylesheetLoader::DEADLINE_KEY]).to be_nil
    end
  end

  describe EmailStylesheetLoader::Cache do
    it "is installed as CSSHelper's cache" do
      expect(Premailer::Rails::CSSHelper.cache).to be_a(described_class)
    end

    it "keeps a loaded stylesheet but not a dropped one" do
      cache = described_class.new
      cache["https://cdn.example.com/a.css"] = seller_css
      cache["https://cdn.example.com/b.css"] = ""

      expect(cache["https://cdn.example.com/a.css"]).to eq(seller_css)
      expect(cache["https://cdn.example.com/b.css"]).to be_nil
    end

    it "expires entries" do
      cache = described_class.new
      cache["https://cdn.example.com/a.css"] = seller_css

      travel(EmailStylesheetLoader::CACHE_TTL + 1.second) do
        expect(cache["https://cdn.example.com/a.css"]).to be_nil
      end
    end

    it "evicts the oldest entries past its size" do
      stub_const("EmailStylesheetLoader::CACHE_SIZE", 2.kilobytes)
      cache = described_class.new
      (1..3).each { cache["https://cdn.example.com/#{_1}.css"] = "a" * 900 }

      expect(cache["https://cdn.example.com/1.css"]).to be_nil
      expect(cache["https://cdn.example.com/3.css"]).to be_present
    end

    it "lets production retry a stylesheet whose fetch failed" do
      original_cache = Premailer::Rails::CSSHelper.cache
      Premailer::Rails::CSSHelper.cache = described_class.new
      allow(Rails.env).to receive(:production?).and_return(true)
      stub_request(:get, "https://cdn.example.com/flaky.css").to_return({ status: 503 }, { status: 200, body: seller_css })

      expect(Premailer::Rails::CSSHelper.css_for_url("https://cdn.example.com/flaky.css")).to eq("")
      expect(Premailer::Rails::CSSHelper.css_for_url("https://cdn.example.com/flaky.css")).to eq(seller_css)
      expect(Premailer::Rails::CSSHelper.css_for_url("https://cdn.example.com/flaky.css")).to eq(seller_css)
      expect(a_request(:get, "https://cdn.example.com/flaky.css")).to have_been_made.twice
    ensure
      Premailer::Rails::CSSHelper.cache = original_cache
    end
  end
end
