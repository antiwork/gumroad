# frozen_string_literal: true

# Premailer strategy for every <link rel="stylesheet"> in an email. Post bodies are seller HTML, so
# any href can land here; one that cannot be loaded safely is dropped instead of raising.
module EmailStylesheetLoader
  extend self

  DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze
  MAX_REDIRECTS = 3
  OPEN_TIMEOUT_SECONDS = 3
  READ_TIMEOUT_SECONDS = 5
  # Bounds the whole fetch, every hop included: read_timeout applies per read, so a server trickling
  # headers or body bytes would otherwise hold the render open.
  FETCH_TIMEOUT_SECONDS = 10
  # Shared by every remote stylesheet in one email, so render time does not grow with each <link>.
  DOCUMENT_TIMEOUT_SECONDS = 15
  MAX_BYTES = 1.megabyte
  CACHE_SIZE = 16.megabytes
  CACHE_TTL = 10.minutes
  DEADLINE_KEY = :email_stylesheet_loader_deadline

  class DisallowedPort < SsrfFilter::Error; end
  class ResponseTooLarge < StandardError; end

  # Replaces CSSHelper's production cache, an unbounded process-lifetime Hash keyed by seller hrefs.
  # A dropped stylesheet ("") is not kept, so a transient failure is retried on the next render.
  class Cache
    def initialize
      @store = ActiveSupport::Cache::MemoryStore.new(size: CACHE_SIZE, expires_in: CACHE_TTL)
    end

    def [](url) = @store.read(url)

    def []=(url, css)
      @store.write(url, css) unless css.empty?
    end
  end

  # Prepended to CSSHelper's singleton: css_for_doc is the only place that sees a whole email.
  module DocumentDeadline
    def css_for_doc(doc)
      Thread.current[DEADLINE_KEY] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DOCUMENT_TIMEOUT_SECONDS
      super
    ensure
      Thread.current[DEADLINE_KEY] = nil
    end
  end

  def load(url)
    css = public_file(url)
    return unwrap_layers(css) if css

    uri = Premailer::Rails::CSSLoaders::NetworkLoader.uri_for_url(url)
    return "" if uri.nil?

    return unwrap_layers(fetch_development_asset(uri) || "") if development_asset_host?(uri)

    fetch(uri) || ""
  rescue URI::Error
    ""
  end

  private
    # Premailer's css_parser has no @layer support and drops rules inside a layer block: the built
    # CSS loses its :root custom properties (--font-family, --color, ...), and the unminified
    # development CSS loses the whole base layer. Only our own stylesheets are unwrapped, because
    # unwrapping a seller's layer would let it outrank the seller's unlayered rules.
    def unwrap_layers(css)
      return css unless css.include?("@layer")

      scanner = StringScanner.new(css)
      output = +""
      closes_layer = []
      until scanner.eos?
        # A header's comments may hold ";" or "{". Every attempt stops at the next "@", so a malformed
        # header is scanned once and then copied as plain text.
        if scanner.scan(%r{@layer\b(?:[^{};@/]|/\*[^@]*?\*/)*([;\{])})
          # A layer order statement (";") has no rules.
          closes_layer.push(true) if scanner[1] == "{"
        elsif scanner.scan("{")
          closes_layer.push(false)
          output << "{"
        elsif scanner.scan("}")
          output << "}" unless closes_layer.pop
        else
          # Strings and comments are copied whole, so braces inside them do not count. An unterminated
          # one runs to the end, so no input is scanned twice.
          output << scanner.scan(%r{"(?:\\.|[^"\\])*(?:"|\z)|'(?:\\.|[^'\\])*(?:'|\z)|/\*.*?(?:\*/|\z)|[^{}"'/@]+|.}m)
        end
      end
      output
    end

    # The gem's FileSystemLoader joins the href's path onto public/ without resolving "..", so a
    # seller href could otherwise read any file on the host.
    def public_file(url)
      # FileSystemLoader raises TypeError on an href with no path, such as mailto:.
      return if URI(url).path.blank?

      path = File.expand_path(Premailer::Rails::CSSLoaders::FileSystemLoader.file_name(url))
      File.read(path) if path.start_with?("#{Rails.public_path}/") && File.file?(path)
    end

    def fetch(uri)
      bounded_fetch(uri) do |read_response|
        SsrfFilter.get(
          uri,
          headers: { "Accept" => "text/css" },
          max_redirects: MAX_REDIRECTS,
          request_proc: method(:check_port),
          # A proxy taken from the environment would resolve the host itself and ignore the address
          # SsrfFilter validated.
          http_options: { open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS, proxy_from_env: false },
          &read_response
        )
      end
    end

    # Shared by both transports, so the development asset host skips address filtering but none of
    # the time or size limits.
    def bounded_fetch(uri)
      timeout = fetch_timeout
      return if timeout <= 0

      css = nil
      read_response = lambda do |http_response|
        raise ResponseTooLarge if http_response["content-length"].to_i > MAX_BYTES

        body = +""
        http_response.read_body do |chunk|
          body << chunk
          raise ResponseTooLarge if body.bytesize > MAX_BYTES
        end
        css = body if http_response.is_a?(Net::HTTPSuccess)
      end
      Timeout.timeout(timeout) { yield read_response }
      css&.force_encoding(Encoding::UTF_8)&.scrub
    # The remote server is seller-controlled and can make Net::HTTP or SsrfFilter raise nearly
    # anything (e.g. ArgumentError from the resolver on a host-less redirect); none of it may fail
    # the email.
    rescue StandardError => e
      Rails.logger.info("[EmailStylesheetLoader] dropped stylesheet from #{uri.host}: #{e.class}")
      nil
    end

    def fetch_timeout
      deadline = Thread.current[DEADLINE_KEY]
      return FETCH_TIMEOUT_SECONDS if deadline.nil?

      [FETCH_TIMEOUT_SECONDS, deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)].min
    end

    # SsrfFilter re-checks the scheme and resolved address on every redirect hop, but never the
    # port. It calls this for each hop too, before connecting.
    def check_port(request)
      raise DisallowedPort, request.uri.to_s unless DEFAULT_PORTS[request.uri.scheme] == request.uri.port
    end

    # In development the email's own CSS comes from the Vite dev server behind the local asset hosts,
    # which SsrfFilter refuses as loopback. Mailer views and ApplicationController.renderer use
    # different ones.
    def development_asset_host?(uri)
      return false unless Rails.env.development?

      [Rails.configuration.action_controller.asset_host, Rails.configuration.action_mailer.asset_host].any? do |asset_host|
        asset_host.is_a?(String) && origin(uri) == origin(URI(asset_host))
      end
    end

    # Single request, no redirects followed.
    def fetch_development_asset(uri)
      bounded_fetch(uri) do |read_response|
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS) do |http|
          http.request(Net::HTTP::Get.new(uri, "Accept" => "text/css"), &read_response)
        end
      end
    end

    def origin(uri) = [uri.scheme, uri.host&.downcase, uri.port]
end
