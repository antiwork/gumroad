# frozen_string_literal: true

# Regenerates the Rails-produced fixtures the go_web rails, session, sidekiq and beacons tests
# compare against. It boots a bare Rails 8.1 app configured like config/application.rb,
# session_store.rb and cookie_rotator.rb, so cookies, CSRF tokens and signed messages come
# from the real implementations rather than from a Go reading of them.
#
#   RBENV_VERSION=3.4.3 ruby go_web/internal/rails/testdata/rails_fixtures.rb

gem "rack", "3.2.6"
gem "activesupport", "8.1.3.1"
gem "actionpack", "8.1.3.1"
gem "railties", "8.1.3.1"
gem "rack-utf8_sanitizer", "1.9.1"
gem "secure_headers", "7.3.0"
gem "json", "2.13.2"

require "json"
require "active_support/all"
require "rails"
require "action_controller/railtie"
require "rack/utf8_sanitizer"
require "secure_headers"
require "uri"
require "tmpdir"

ROOT = File.expand_path("../../../..", __dir__)
SECRET_KEY_BASE = "go-web-test-secret-key-base"
SESSION_KEY = "_gumroad_app_session"

class FixtureApp < Rails::Application
  config.root = Dir.mktmpdir
  config.load_defaults 8.1
  # Mirrors config/application.rb. PublicExceptions uses it as the charset; the default,
  # Encoding::UTF_8, prints "UTF-8".
  config.encoding = "utf-8"
  config.action_controller.escape_json_responses = true
  config.active_support.escape_js_separators_in_json = true
  config.eager_load = false
  config.secret_key_base = SECRET_KEY_BASE
  config.logger = Logger.new(nil)
  config.hosts.clear
  config.action_controller.allow_forgery_protection = true
  config.session_store :cookie_store, key: SESSION_KEY, secure: true, domain: :all, expire_after: 1.month, tld_length: 2
  config.active_support.message_serializer = :json_allow_marshal
  config.active_support.use_message_serializer_for_metadata = true

  config.after_initialize do
    config.action_dispatch.cookies_rotations.tap do |cookies|
      key_generator = ActiveSupport::KeyGenerator.new(SECRET_KEY_BASE, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA1)
      cookies.rotate :encrypted, key_generator.generate_key(config.action_dispatch.authenticated_encrypted_cookie_salt, ActiveSupport::MessageEncryptor.key_len)
      cookies.rotate :signed, key_generator.generate_key(config.action_dispatch.signed_cookie_salt)
    end
  end

  routes.append do
    get "/seed" => "fixtures#seed"
    match "/check" => "fixtures#check", via: [:get, :post]
    match "/media_locations" => "fixtures#check", via: [:post]
    get "/redirect" => "fixtures#redirect_to_login"
    get "/delete_seller" => "fixtures#delete_seller"
    get "/unauthorized" => "fixtures#unauthorized"
    get "/gif" => "fixtures#gif"
    get "/json" => "fixtures#json"
    get "/write_session" => "fixtures#write_session"
    get "/cookie_lines" => "fixtures#cookie_lines"
  end
end

class FixturesController < ActionController::Base
  protect_from_forgery

  def seed
    session["warden.user.user.key"] = [[1_000_001], "$2a$11$abcdefghijklmnopqrstuv"]
    session["warden.user.user.session"] = { "last_sign_in_at" => 1_790_000_000 }
    session[:signup_referrer] = "www.google.com"
    session[:mobile_param] = "1"
    cookies.permanent.encrypted[:current_seller_id] = { value: 1_000_002, domain: :all }
    render json: {
      global: form_authenticity_token,
      per_form: form_authenticity_token(form_options: { action: "/media_locations", method: "post" }),
    }
  end

  def check
    render json: { verified: session.enabled?, user_key: session["warden.user.user.key"], seller: cookies.encrypted[:current_seller_id] }
  end

  def redirect_to_login
    redirect_to "/login"
  end

  def delete_seller
    cookies.delete(:current_seller_id, domain: :all)
    head :ok
  end

  def unauthorized
    headers.merge!("Cache-Control" => "no-store, no-cache", "WWW-Authenticate" => 'Bearer realm="Doorkeeper", error="invalid_token", error_description="The access token is invalid"')
    head :unauthorized
  end

  def gif
    expires_now
    send_data "GIF89a".b, type: "image/gif", disposition: "inline"
  end

  def json
    render json: { success: true }
  end

  # A plain cookie, as inertia_rails writes XSRF-TOKEN, and domain: :all with a tld_length.
  def cookie_lines
    cookies["XSRF-TOKEN"] = "a+b/c="
    cookies[:tld] = { value: "v", domain: :all, tld_length: 2 }
    cookies[:tld3] = { value: "v", domain: :all, tld_length: 3 }
    head :ok
  end

  # A new session, written once: keys land in the order they are set, nil values are
  # dropped, and the CSRF token is stored last, at commit.
  def write_session
    session[:signup_referrer] = "<a href=\"x\">&amp;</a> /\u00fc\u2028 \u2713"
    session[:recommender_model_name] = "sales"
    session[:dropped] = nil
    session[:nested] = { "a" => [1, 2.5, nil, true] }
    form_authenticity_token
    head :ok
  end
end

SecureHeaders::Configuration.default do |c|
  c.cookies = { httponly: true, secure: true, samesite: { none: true } }
  c.csp = SecureHeaders::OPT_OUT
end
FixtureApp.initialize!
APP = Rails.application

def request(method, path, headers: {}, body: nil)
  env = Rack::MockRequest.env_for("https://gumroad.com#{path}", { method:, input: body }.compact.merge(headers))
  status, response_headers, response_body = APP.call(env)
  text = +""
  response_body.each { |part| text << part }
  [status, response_headers, text]
end

def set_cookies(headers)
  Array(headers["set-cookie"]).flat_map { |h| h.split("\n") }
end

def cookie_value(set_cookie_lines, name)
  line = set_cookie_lines.find { |l| l.start_with?("#{name}=") }
  Rack::Utils.unescape(line.split(";", 2).first.split("=", 2).last)
end

def write(path, data)
  full = File.join(ROOT, "go_web/internal", path)
  File.write(full, JSON.pretty_generate(data) + "\n")
  puts "wrote #{full}"
end

# --- session cookies and CSRF ---

_, seed_headers, seed_body = request("GET", "/seed")
seed_cookies = set_cookies(seed_headers)
session_cookie = cookie_value(seed_cookies, SESSION_KEY)
seller_cookie = cookie_value(seed_cookies, "current_seller_id")
tokens = JSON.parse(seed_body)
cookie_header = "#{SESSION_KEY}=#{Rack::Utils.escape(session_cookie)}; current_seller_id=#{Rack::Utils.escape(seller_cookie)}"

encrypted_jar = ActionDispatch::Request.new(APP.env_config.merge(Rack::MockRequest.env_for("https://gumroad.com/"))).cookie_jar.encrypted
session_plain = encrypted_jar.send(:parse, SESSION_KEY, session_cookie, purpose: "cookie.#{SESSION_KEY}")

sha1_generator = ActiveSupport::KeyGenerator.new(SECRET_KEY_BASE, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA1)
old_encryptor = ActiveSupport::MessageEncryptor.new(
  sha1_generator.generate_key("authenticated encrypted cookie", 32),
  cipher: "aes-256-gcm", serializer: ActiveSupport::MessageEncryptor::NullSerializer
)
rotated_value = { "warden.user.user.key" => [[1_000_003], "salt"], "session_id" => "abc" }
rotated_cookie = old_encryptor.encrypt_and_sign(JSON.generate(rotated_value), expires_at: Time.utc(2100, 1, 1), purpose: "cookie.#{SESSION_KEY}")
expired_cookie = old_encryptor.encrypt_and_sign(JSON.generate(rotated_value), expires_at: Time.utc(2001, 1, 1), purpose: "cookie.#{SESSION_KEY}")
wrong_purpose_cookie = old_encryptor.encrypt_and_sign(JSON.generate(rotated_value), purpose: "cookie.other")
no_metadata_cookie = old_encryptor.encrypt_and_sign(JSON.generate(rotated_value))

read_back = lambda do |value|
  _, _, body = request("GET", "/check", headers: { "HTTP_COOKIE" => "#{SESSION_KEY}=#{Rack::Utils.escape(value)}" })
  JSON.parse(body)["user_key"]
end

csrf_cases = []
real_token = session_plain["_csrf_token"]
raw_real = Base64.urlsafe_decode64(real_token)
candidates = {
  "global" => tokens["global"],
  "per_form" => tokens["per_form"],
  "unmasked_real" => Base64.urlsafe_encode64(raw_real, padding: false),
  "standard_base64_global" => Base64.strict_encode64(Base64.urlsafe_decode64(tokens["global"])),
  "garbage" => "not-a-token",
  "wrong_length" => Base64.urlsafe_encode64("x" * 40, padding: false),
  "other_session" => Base64.urlsafe_encode64(SecureRandom.random_bytes(64), padding: false),
  "empty" => "",
}
candidates.each do |name, token|
  [["/media_locations", nil], ["/check", nil], ["/check", "https://gumroad.com"], ["/check", "https://evil.example"]].each do |path, origin|
    headers = { "HTTP_COOKIE" => cookie_header, "HTTP_X_CSRF_TOKEN" => token }
    headers["HTTP_ORIGIN"] = origin if origin
    status, _, body = request("POST", path, headers:)
    csrf_cases << { name:, token:, path:, origin:, status:, verified: JSON.parse(body)["verified"] }
  end
end
null_origin_status, = request("POST", "/check", headers: { "HTTP_COOKIE" => cookie_header, "HTTP_X_CSRF_TOKEN" => tokens["global"], "HTTP_ORIGIN" => "null" }) rescue [$!.class.name]

redirect_status, redirect_headers, redirect_body = request("GET", "/redirect")

responses = {}
[["delete_seller", "/delete_seller", { "HTTP_COOKIE" => "current_seller_id=abc" }],
 ["unauthorized_json", "/unauthorized", { "HTTP_ACCEPT" => "application/json, text/html" }],
 ["unauthorized_plain", "/unauthorized", {}],
 ["gif", "/gif", {}],
 ["json", "/json", { "HTTP_ACCEPT" => "application/json, text/html" }]].each do |name, path, headers|
  status, h, body = request("GET", path, headers:)
  responses[name] = { status:, headers: h.to_h.slice("content-type", "cache-control", "etag", "set-cookie", "content-disposition", "content-transfer-encoding", "vary", "www-authenticate"), body: body.b.bytes }
end
public_exceptions = ActionDispatch::PublicExceptions.new(File.join(ROOT, "public"))
[["404_json", 404, "application/json, text/html"], ["404_html", 404, "text/html"], ["404_xml", 404, "application/xml"], ["422_json", 422, "application/json"], ["500_json", 500, "application/json"]].each do |name, code, accept|
  status, h, body = public_exceptions.call(Rack::MockRequest.env_for("https://gumroad.com/#{code}", "HTTP_ACCEPT" => accept))
  text = +""
  body.each { |b| text << b }
  responses[name] = { status:, headers: h.to_h, body: text.b.bytes }
end
write("rails/testdata/rails_responses.json", responses)

_, written_headers, = request("GET", "/write_session")
written_line = set_cookies(written_headers).find { |l| l.start_with?("#{SESSION_KEY}=") }
written_value = cookie_value([written_line], SESSION_KEY)
primary_key = ActiveSupport::KeyGenerator.new(SECRET_KEY_BASE, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA256)
  .generate_key("authenticated encrypted cookie", 32)
data, iv, tag = written_value.split("--").map { |part| Base64.strict_decode64(part) }
cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
cipher.key = primary_key
cipher.iv = iv
cipher.auth_tag = tag
cipher.auth_data = ""
written_envelope = cipher.update(data) + cipher.final

cookie_hosts = ["gumroad.com", "seller.gumroad.com", "a.b.gumroad.com", "shop.example.co.uk", "localhost", "10.0.0.1"]
write("rails/testdata/cookie_writing.json", {
        lines: cookie_hosts.index_with do |host|
          _, headers, = APP.call(Rack::MockRequest.env_for("https://#{host}/cookie_lines"))
          set_cookies(headers)
        end,
        escape: ["a b", "+/=", "\u00fc", "~*-._!'()", "%", "a\u2028b", "--"].index_with { |input| Rack::Utils.escape(input) },
        cgi_escape: ["a b", "+/=", "\u00fc", "~*-._!'()", "%", "/d/x?a=1&b=2"].index_with { |input| CGI.escape(input) },
        to_query: [{ id: "a b/c", destination: "download_page", display: "x~*" }, { next: "/d/x?a=1&b=2" }, { b: "1", a: "2", "a b" => "3" }]
          .map { |h| { pairs: h.map { |k, v| [k.to_s, v] }, query: h.to_query } },
        months: [Time.utc(2026, 1, 31, 10, 0, 0, 123_456), Time.utc(2026, 3, 31), Time.utc(2024, 1, 29), Time.utc(2026, 12, 15, 23, 59, 59)]
          .map { |t| { from: t.iso8601(6), plus_month: (t + 1.month).iso8601(6) } },
      })

write("session/testdata/rails_cookies.json", {
        written_session: { set_cookie: written_line, envelope: written_envelope },
        secret_key_base: SECRET_KEY_BASE,
        session_cookie:,
        session_plaintext: session_plain,
        current_seller_cookie: seller_cookie,
        rotated_cookie:,
        rotated_read_back: read_back.call(rotated_cookie),
        expired_cookie:,
        expired_read_back: read_back.call(expired_cookie),
        wrong_purpose_cookie:,
        wrong_purpose_read_back: read_back.call(wrong_purpose_cookie),
        no_metadata_cookie:,
        no_metadata_read_back: read_back.call(no_metadata_cookie),
        csrf_cases:,
        null_origin: null_origin_status,
        redirect: { status: redirect_status, location: redirect_headers["location"], body: redirect_body },
      })

# --- analytics view tokens (Link.analytics_view_verifier) ---

verifier = APP.message_verifier(:product_analytics_view)
payload = { product_id: 1_000_101, source_url: "https://example.com/landing?a=1", event_id: "11111111-2222-4333-8444-555555555555" }
write("rails/testdata/analytics_tokens.json", {
        secret_key_base: SECRET_KEY_BASE,
        valid: verifier.generate(payload, purpose: :external_landing_page_view, expires_at: Time.utc(2100, 1, 1)),
        expired: verifier.generate(payload, purpose: :external_landing_page_view, expires_at: Time.utc(2001, 1, 1)),
        script_purpose: verifier.generate({ product_id: 1_000_101 }, purpose: :external_landing_page_script),
        no_expiry: verifier.generate(payload, purpose: :external_landing_page_view),
        payload:,
      })

# --- Time.zone.parse (record_media_location's consumed_at) ---

Time.zone = "UTC"
time_inputs = [
  "2015-09-10T00:26:50.000Z", "2015-09-09T17:26:50PDT", "2015-09-09T17:26:50 PDT", "2015-09-09T17:26:50-07:00",
  "2015-09-09T17:26:50+0530", "2015-09-09 17:26:50", "2015-09-09 17:26:50 UTC", "2015-09-09T17:26:50.123456789Z",
  "2015-09-09T17:26Z", "2015-09-09", "2015-09-09T17:26:50EST", "2015-09-09T17:26:50GMT", "2015-09-09T17:26:50CEST",
  "2015-09-09T17:26:50XYZ", "2015-09-09T17:26:50+05", "2015-09-09T17:26:50.5+05:30", "2015-9-9T7:6:5Z",
  "20150909T172650Z", "Wed, 09 Sep 2015 17:26:50 GMT", "Wed, 09 Sep 2015 17:26:50 +0000", "2015-09-09T24:00:00Z",
  "2015-13-09T17:26:50Z", "2015-02-30T10:00:00Z", "abc", "", "  2015-09-09T17:26:50Z  ", "1441819610",
  "2015-09-09t17:26:50z", "2015-09-09T17:26:50.000+00:00", "2026-11-02T10:00:00.999Z", "2015-09-09T17:26:61Z",
  "2015-09-09T17:26:50 -0700", "2015-09-09T17:26:50 Z", "2015-09-09T17:26:50PST", "2015-09-09T17:26:50pdt",
  "2015-09-09T17:26:50 America/Los_Angeles", "Sep 9 2015 17:26", "2015-09-09T17:26:50.Z",
  "20150909T172650+0530", "20150909T172650-0800", "2015-09-09T24:30:00Z", "2015-09-09T05:26:50pm", "2015-09-09 5:26 PM PDT",
  "2015-09-09T17:26:50 pdt dst", "2015-09-09T17:26:50 utc+05:30", "2015-09-09T17:26:50 GMT+5", "2015-09-09T17:26:50+530",
  "2015-09-09T17:26:50+05:30:15", "2015-09-09T17:26:50+2400", "2015-09-09T17:26:50 IST", "09 Sep 2015 17:26:50 +0100",
  "Wednesday, 09-Sep-15 17:26:50 GMT", "2015-09-09T17:26:50.123+05:30", "17:26:50", "2015-09-09T17:26:50 Pacific Standard Time",
  "2015-09-09T17:26:50+5.5", "2015-09-09T17:26:50 garbage", "2015-09-00T10:00:00Z", "2015-09-32T10:00:00Z",
  "#{"x" * 130}2015-09-09",
]
datetime_inputs = [
  "2026-11-02 10:00:00 UTC", "2026-11-02 10:00:00 +0000", "2026-11-02T10:00:00.123Z", "2026-11-02T10:00:00-07:00",
  "2015-02-30 10:00:00", "2015-09-09T24:00:00Z", "2015-09-09T23:59:60Z", "2015-09-09T17:26:50PDT", "2015-09-09",
  "2015-09-09T17:26:50+2400", "2015-13-01", "abc", "", " ", "2015-09-09T25:00:00Z", "2015-09-09T17:26:50+0530",
  "2015-02-29", "2016-02-29 10:00 UTC", "2026-11-02 10:00:00.5 +0100", "Mon, 02 Nov 2026 10:00:00 GMT",
]
write("rails/testdata/datetime_parse.json", datetime_inputs.map do |input|
  result = begin
    dt = input.to_datetime
    dt ? { time: dt.iso8601(9), offset: (dt.offset * 86400).to_i } : { nil: true }
  rescue ArgumentError, Date::Error => e
    { error: e.message }
  end
  { input: }.merge(result)
end)

write("rails/testdata/time_parse.json", time_inputs.map do |input|
  result = begin
    t = Time.zone.parse(input)
    t ? { time: t.utc.iso8601(9) } : { nil: true }
  rescue ArgumentError => e
    { error: e.message }
  end
  { input: }.merge(result)
end)

# --- ActionDispatch's JSON parameter parser, then from_hash's encoding check and deep munge ---

json_inputs = [
  "[" * 100 + "]" * 100, "[" * 101 + "]" * 101, "[" * 102 + "]" * 102, "[" * 101 + "1" + "]" * 101,
  "[" * 100 + "1" + "]" * 100, "{\"a\":" * 100 + "1" + "}" * 100, "{\"a\":" * 101 + "{}" + "}" * 101,
  %q({"s":"\ud800"}), %q({"s":"\udc00"}), %q({"\udc00":1}), %q({"a":[{"b":"\udc00"}]}), %q(["\udc00"]),
  %q({"s":"\ud800\ud800"}), %q({"s":"\ud800x"}), %q({"s":"\ud800abcdefg"}), %q({"s":"\ud83d\ude00"}),
  %q(["\u12"]), %q(["\uZZZZ"]), "/* c */ {\"a\":1}", "{\"a\":1 // x\n}", "{\"a\":1 /* x */}", "/* open", "[1,]",
  "{\"a\":1,}", "\"a\u0001b\"", "[\"a\\x\"]", "[01]", "[1.]", "[.5]", "[-]", "[+1]", "[NaN]", "[1e400]",
  "{\"a\":1,\"a\":2,\"b\":3}", " 1 ", "\"x\"", "null", "[\"\\u0000\"]", "[1 2]", "\f[1]", "[\"\\/\"]",
  "{\"a\" : 1}", "[1]x", "[] []", "[\"a\tb\"]", "[-0]", "[1E2]", "[1e+2]", "[\"\\U0041\"]", "[true,false,null]",
  "[tru]", "{\"a\":[1,null,[null,2]],\"n\":null}", "  ", "{\"x\":\"\\\"\"}", "[123456789012345678901234567890]",
  "{\"a\":\"\\u00e9\\n\"}", "[\"\\",
]
write("rails/testdata/json_params.json", json_inputs.map do |input|
  result = begin
    data = ActiveSupport::JSON.decode(input)
    data = { "_json" => data } unless data.is_a?(Hash)
    ActionDispatch::Request::Utils.check_param_encoding(data)
    { inspect: ActionDispatch::Request::Utils.normalize_encode_params(data).to_hash.inspect }
  rescue JSON::ParserError
    { error: "ParseError" }
  rescue Rack::Utils::InvalidParameterError
    { error: "BadRequest" }
  end
  { input: input.b.bytes }.merge(result)
end)

# --- Rack::UTF8Sanitizer and Rack's query and cookie parsing ---

sanitizer = Rack::UTF8Sanitizer.new(nil)
uri_inputs = [
  "https://example.com/a b", "https://example.com/%7euser", "https://example.com/caf%c3%a9", "https://example.com/café",
  "https://example.com/%E9", "https://example.com/\xFF".b, "https://example.com/?q=%2F%3F&x=%41", "/links/abc/increment_views",
  "https://example.com/{a}|^`\"<>", "a=1&b=%zz", "https://example.com/\xC3\xA9\xFF".b, "%00%01", "https://example.com/#frag",
]
write("rails/testdata/utf8_sanitizer.json", uri_inputs.map do |input|
  { input: input.dup.force_encoding("BINARY").bytes, output: sanitizer.send(:sanitize_uri_encoded_string, input.dup).b.bytes }
end + [{ header: true, input: "Mozilla \xFF caf\xC3\xA9".b.bytes, output: sanitizer.send(:sanitize_string, "Mozilla \xFF caf\xC3\xA9".b).b.bytes }])

query_inputs = [
  "a=1&b=2", "a=1&a=2", "a[]=1&a[]=2", "a[b]=1&a[c]=2", "a[b][]=1", "a+b=c+d", "a=%20%2B", "a", "a=", "=a", "a[]=1&a=2",
  "a=1&a[]=2", "a[b]=1&a=2", "&&a=1&&", "a[=1", "a]=1", "a[b]c=1", "a[][b]=1&a[][c]=2&a[][b]=3",
]
write("rails/testdata/rails_query.json", query_inputs.map do |input|
  result = begin
    { params: ActionDispatch::ParamBuilder.from_query_string(input).to_h }
  rescue StandardError => e
    { error: e.class.name }
  end
  { input: }.merge(result)
end)

cookie_inputs = ["a=1; b=2", "a=1;b=2", "a=1; a=2", "a=%20+x", "a=%zz", "a", "a=1=2", " a=1", "a=1,b=2"]
write("rails/testdata/rack_cookies.json", cookie_inputs.map do |input|
  env = { "HTTP_COOKIE" => input.dup }
  sanitizer.send(:sanitize_cookies, env)
  { input:, sanitized: env["HTTP_COOKIE"], cookies: Rack::Utils.parse_cookies_header(env["HTTP_COOKIE"]) }
end)

# --- Referrer.extract_domain (lib/utilities/referrer.rb) ---

def extract_domain(url)
  return "direct" if url.blank? || url == "direct"

  domain = begin
    url = URI::DEFAULT_PARSER.unescape(url)
    url.encode!("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "")
    url.gsub!(/\s+/, "")
    host = URI.parse(url).host.try(:downcase)
    return "direct" if host.blank?

    host.start_with?("www.") ? host[4..-1] : host
  rescue URI::InvalidURIError, Encoding::CompatibilityError
  end

  domain.presence || "direct"
end

referrers = [
  "https://www.Example.com/path?q=1", "http://example.com", "example.com/path", "//cdn.example.com/x", "direct", "",
  "https://example.com/a b", "https://ex ample.com/", "https://例え.jp/", "https://xn--r8jz45g.jp/", "https://user:pw@example.com:8080/",
  "https://[::1]:80/", "https://example.com/%7B", "https://example.com/{", "android-app://com.google.android.gm/",
  "https://www.google.com/url?q=https://other.example", "https://exa%6dple.com/", "https://example.com:abc/", "mailto:x@example.com",
  "https://www./", "https://www.www.example.com", "file:///etc/passwd", "https://example.com\\foo", "https://EXAMPLE.COM.",
  "https://-bad-.example.com/", "https://under_score.example.com/", "http://192.168.0.1/", "https://example.com/%",
]
write("beacons/testdata/referrer_domains.json", referrers.map { |r| { input: r, domain: extract_domain(r.dup) } })

# --- JSON.generate as Sidekiq.dump_json uses it ---

json_values = [
  { "a" => "<script>&</script>", "b" => "line sep ", "c" => "é\u0001\u001f\u007f", "d" => "\\\"/" },
  [1.0, 0.1, 1.5e-5, 1.0e16, 1234567.0, 1730000000.123456, 1e20, -0.0, 100.0, 12345678901234567.0, 0.0001],
  [nil, true, false, 12_345_678_901_234_567_890, -5],
]
write("sidekiq/testdata/ruby_json.json", json_values.map { |v| { value: v, json: JSON.generate(v), floats: (v.is_a?(Array) && v.first.is_a?(Float)) ? v.map(&:to_s) : nil } })

# --- the _gumroad_guid cookie as Rack writes it and SecureHeaders flags it ---

guid_line = Rack::Utils.set_cookie_header("_gumroad_guid", { value: "11111111-2222-4333-8444-555555555555", domain: "gumroad.com", path: "/", expires: Time.utc(2036, 11, 2, 10, 0, 0), httponly: true, same_site: :lax })
cookie_config = { httponly: true, secure: true, samesite: { none: true } }
write("rails/testdata/guid_cookie.json", {
        rack: guid_line,
        secure_headers: SecureHeaders::Cookie.new(guid_line.dup, SecureHeaders::Cookie::COOKIE_DEFAULTS.merge(cookie_config)).to_s,
      })

bots = eval(File.read(File.join(ROOT, "config/initializers/bots.rb")).sub("# frozen_string_literal: true", "").sub(/\ABOT_MAP = /m, "").strip.sub(/\ABOT_MAP\s*=\s*/, ""))
write("rails/bot_map.json", bots.keys)

# --- Date._parse's zone table, from the date gem's source ---

zonetab = File.join(Gem::Specification.find_by_name("date").full_gem_path, "ext/date/zonetab.list")
zones = File.read(zonetab).split("%%")[1].lines.map(&:strip).reject(&:empty?).map do |line|
  name, expr = line.rpartition(",").values_at(0, 2)
  # The offsets are C integer expressions such as -(3*3600+30*60), which Ruby reads the same way.
  [name.strip, Integer(eval(expr))]
end.uniq(&:first)
width = zones.map { |name, _| name.length }.max + 3
zones_go = File.join(ROOT, "go_web/internal/rails/zones.go")
File.write(zones_go, <<~GO)
  // Code generated from the date gem's ext/date/zonetab.list (date #{Gem::Specification.find_by_name("date").version}) by testdata/rails_fixtures.rb. DO NOT EDIT.

  package rails

  // zoneOffsets is Date._parse's zone table: lowercased names to UTC offsets in seconds.
  var zoneOffsets = map[string]int{
  #{zones.map { |name, offset| "\t#{"#{name.to_json}:".ljust(width)}#{offset}," }.join("\n")}
  }
GO
system("gofmt", "-w", zones_go, exception: true)
puts "wrote zones.go"
