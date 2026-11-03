# frozen_string_literal: true

# Writes params.json and time_ago.json from the real gems: RBENV_VERSION=3.4.3 ruby testdata/vectors.rb testdata
gem "actionpack", "8.1.3.1"
gem "actionview", "8.1.3.1"
gem "activesupport", "8.1.3.1"
gem "rack", "3.2.6"
gem "rack-utf8_sanitizer", "1.9.1"
gem "json", "2.13.2"
require "json"
require "action_dispatch"
require "action_controller"
require "action_view"
require "rack/utf8_sanitizer"
require "active_support/all"
ActiveSupport::JSON::Encoding.time_precision = 0
ActiveSupport.escape_js_separators_in_json = true
I18n.load_path += Dir[File.join(Gem.loaded_specs["actionview"].full_gem_path, "lib/action_view/locale/*.yml")]
I18n.load_path += Dir[File.join(Gem.loaded_specs["activesupport"].full_gem_path, "lib/active_support/locale/*.yml")]

def canon(v)
  case v
  when nil then nil
  when true, false then v
  when String then "s:" + v
  when Numeric then "n:" + v.to_s
  when Array then v.map { canon(_1) }
  when Hash, ActiveSupport::HashWithIndifferentAccess then v.to_h.sort_by { |k, _| k.to_s }.to_h { |k, val| [k.to_s, canon(val)] }
  when ActionDispatch::Http::UploadedFile then "file"
  else "?" + v.class.name
  end
end

def params_for(method: "POST", query: "", body: "", ctype: nil, format: nil)
  path = "/v2/licenses/verify"
  env = Rack::MockRequest.env_for("http://api.gumroad.com#{path}", method: method, input: body.b)
  env["QUERY_STRING"] = query.b
  if ctype then env["CONTENT_TYPE"] = ctype else env.delete("CONTENT_TYPE") end
  env = Rack::UTF8Sanitizer.new(->(e) { [200, {}, [e]] }).call(env)[2][0]
  r = ActionDispatch::Request.new(env)
  pp = { controller: "api/v2/licenses", action: "verify" }
  pp[:format] = format if format
  r.path_parameters = pp
  begin
    canon(r.params.to_h)
  rescue ActionController::BadRequest
    "error:bad_request"
  rescue ActionDispatch::Http::Parameters::ParseError
    "error:json_parse"
  rescue Rack::QueryParser::QueryLimitError
    "error:query_limit"
  rescue ActionDispatch::Http::MimeNegotiation::InvalidType
    "error:invalid_mime"
  end
end

form = "application/x-www-form-urlencoded"
param_cases = [
  { query: "license_key=a&license_key=b" },
  { query: "license_key=a", body: "license_key=b", ctype: form },
  { body: "license_key=b&& product_id=x&&&", ctype: form },
  { body: "license_key=b&increment_uses_count=false" },
  { body: "license_key=b", ctype: "" },
  { body: "license_key=b", ctype: "text" },
  { body: "license_key=b", ctype: "foo bar" },
  { body: "license_key=b", ctype: ";charset=utf-8" },
  { body: '{"a":1}', ctype: " application/json , text/plain" },
  { body: "license_key=b", ctype: "*/*" },
  { body: "license_key[]=b&license_key[]&license_key[]=c", ctype: form },
  { body: "license_key[x]=b&id&link_id=", ctype: form },
  { body: "a=%zz", ctype: form },
  { body: "a=%2", ctype: form },
  { query: "a=%", },
  { body: "a=1&a[]=2", ctype: form },
  { body: "a[]=1&a[x]=2", ctype: form },
  { body: "a=1&a[x]=2", ctype: form },
  { body: "a&a[x]=2&b&b[]=3", ctype: form },
  { query: "a=%C3%A9&b=%FF" },
  { query: "a=%C3%A9" },
  { query: "a=caf\xC3\xA9&b=\xFF" },
  { query: "a=caf\xC3\xA9" },
  { query: "k=%2B%26%3D%20+x" },
  { body: "a=%C3%A9&b=%FF", ctype: form },
  { body: "a=%FF", ctype: "multipart/form-data" },
  { body: "a=\xFF" },
  { body: '{"license_key":"x","increment_uses_count":false,"n":[null,1,[null]],"h":{},"f":1.5,"big":123456789012345678901234567890}', ctype: "application/json" },
  { body: "[1,2]", ctype: "application/json" },
  { body: '"str"', ctype: "application/json; charset=utf-8" },
  { body: "{bad", ctype: "application/json" },
  { body: '{"a":1} x', ctype: "application/json" },
  { body: "  ", ctype: "application/json" },
  { body: "\xEF\xBB\xBF{\"a\":1}", ctype: "application/json" },
  { body: "{\"a\":\"caf\xC3\xA9\xFF\"}", ctype: "application/json" },
  { body: '{"a":1}', ctype: "application/vnd.api+json" },
  { body: '{"a":1}', ctype: "text/x-json" },
  { body: '{"a":1}', ctype: "Application/JSON" },
  { body: "a=1", ctype: "text/plain" },
  { body: "a+b=c+d%2B&e=%7e%41", ctype: "application/x-www-form-urlencoded; charset=UTF-8" },
  { query: "=x&[a]=1&b[=2&c]=3&d[e]f=4&g[][h]=5&g[][i]=6&g[][h]=7&j[][]=8" },
  { query: "a[b][c][d]=1&a[b][e]=2" },
  { query: "license_key=x", format: "json" },
  { query: "format=xml&controller=evil" },
  { body: "--XX\r\nContent-Disposition: form-data; name=\"license_key\"\r\n\r\nabc\r\n--XX\r\nContent-Disposition: form-data; name=\"product_id\"; filename=\"f.txt\"\r\nContent-Type: text/plain\r\n\r\nfile\r\n--XX\r\nContent-Disposition: form-data; name=\"id[]\"\r\n\r\nz\r\n--XX--\r\n", ctype: "multipart/form-data; boundary=XX" },
  { body: "x=1\x00", ctype: "" },
  { body: "x=1\x00", ctype: form },
  { query: (["a[b]"] * 1).join + "=1&" + ("a" * 3) },
  { query: "a" + "[b]" * 101 + "=1" },
  { body: "a" + "[b]" * 40 + "=1", ctype: form },
  { body: (1..4097).map { "k#{_1}=v" }.join("&"), ctype: form },
]
params_out = param_cases.map do |c|
  { "method" => "POST", "query" => c[:query].to_s.b.unpack1("H*"), "body" => c[:body].to_s.b.unpack1("H*"), "content_type" => c[:ctype], "format" => c[:format].to_s, "want" => params_for(**c) }
end
File.write(ARGV[0] + "/params.json", JSON.pretty_generate(params_out))

include ActionView::Helpers::DateHelper
now = Time.utc(2026, 11, 2, 12, 0, 0)
offsets = [0, 29, 30, 89, 90, 2699, 2700, 5399, 5400, 86340, 86400, 151199, 151200, 2591999, 2592000, 5183999, 5184000, 31535999, 31536000, 39_000_000, 47_000_000, 60_000_000, 63_072_000, 100_000_000, 3_155_760_000, -100]
ago = offsets.map { |o| from = now - o; { "from" => from.iso8601, "now" => now.iso8601, "want" => time_ago_in_words(from).then { |w| distance_of_time_in_words(from, now) } } }
File.write(ARGV[0] + "/time_ago.json", JSON.pretty_generate(ago))
