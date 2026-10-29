# frozen_string_literal: true

# The HTML a build's frame gets: the seller's page with the save shim put in front of every script,
# and the CSP that keeps it on an opaque origin even when the URL is opened outside the frame.
module ProductBuilds::PlayerDocument
  SANDBOX = "allow-scripts allow-pointer-lock"
  # How long the shim gathers storage writes before it sends them in one batch.
  SAVE_FLUSH_DELAY_MS = 1_000
  # Browsers cap a beacon (and all keepalive requests together) at 64 KB; a larger last batch goes
  # out as an ordinary request, which the browser may cancel as the page closes.
  SAVE_BEACON_MAX_BYTES = 60_000
  SAVE_FAILED_MESSAGE_TYPE = "gumroad:build-save-failed"
  # Network errors are retried quietly at first; the buyer hears about it only if they keep failing.
  SAVE_FAILURES_BEFORE_ALERT = 3
  # Prefix of the window.name that carries unconfirmed changes from one page of a build to the next.
  CARRIED_CHANGES_PREFIX = "gumroad-build-save:"

  # The save shim, which puts localStorage back on the opaque origin. It lives in its own file so a
  # test can run it; see the file for how it saves.
  SAVE_SHIM_SCRIPT = Rails.root.join("app/javascript/build_player/save_shim.js").read.freeze
  SAVE_SHIM_CONFIG_MARKER = "JSON.parse(__CONFIG__)"

  # A UTF-8 byte order mark, leading whitespace and comments, then the doctype if there is one.
  PROLOGUE = /\A(?:\xEF\xBB\xBF)?(?:\s|<!--.*?-->)*(?:<!doctype[^>]*>)?/imn

  # The seller's page is bytes in whatever encoding they wrote it in, so the scripts go in as ASCII
  # bytes right after the doctype, before any tag of the page. There the parser opens <html> and <head>
  # for them, so no tag has to be found, and a <head> inside a comment or a script cannot mislead it.
  # Anything before the doctype would put the page in quirks mode.
  def self.render(html, save_data:, save_url:)
    config = {
      save: save_data,
      saveUrl: save_url,
      flushDelayMs: SAVE_FLUSH_DELAY_MS,
      beaconMaxBytes: SAVE_BEACON_MAX_BYTES,
      failedMessageType: SAVE_FAILED_MESSAGE_TYPE,
      failuresBeforeAlert: SAVE_FAILURES_BEFORE_ALERT,
      carriedPrefix: CARRIED_CHANGES_PREFIX,
      maxWriterIdLength: ProductBuildSave::MAX_WRITER_ID_LENGTH,
    }
    # A JSON string of the JSON, ASCII only: it reads the same whatever encoding the seller's page is
    # in, and json_escape keeps a "</script>" in a saved value from ending the script.
    literal = JSON.generate(JSON.generate(config, ascii_only: true), ascii_only: true)
    script = SAVE_SHIM_SCRIPT.sub(SAVE_SHIM_CONFIG_MARKER) { "JSON.parse(#{ERB::Util.json_escape(literal)})" }
    # data-cfasync: Rocket Loader must not run the save shim after the in-memory stand-ins.
    injected = %(<script data-cfasync="false">#{script}</script>#{RendersCustomHtmlPages::SANDBOX_COMPAT_SCRIPT}).b
    html = html.b
    html.insert(html.match(PROLOGUE).end(0), injected)
  end

  # `request_origin` is the app or custom-domain origin serving the frame, and `cdn_origin` the
  # host the build's other files redirect to. 'self' is not used: on a sandboxed document it would
  # not match the frame's own URL in every browser.
  def self.content_security_policy(request_origin:, cdn_origin:)
    hosts = "#{request_origin} #{cdn_origin}"
    [
      "sandbox #{SANDBOX}",
      "default-src 'none'",
      "script-src #{hosts} 'unsafe-inline' 'wasm-unsafe-eval' blob:",
      "style-src #{hosts} 'unsafe-inline' blob: data:",
      "img-src #{hosts} blob: data:",
      "media-src #{hosts} blob: data:",
      "font-src #{hosts} blob: data:",
      "connect-src #{hosts} blob: data:",
      "worker-src blob:",
      "frame-ancestors #{request_origin}",
      "form-action 'none'",
      "base-uri 'none'",
    ].join("; ")
  end
end
