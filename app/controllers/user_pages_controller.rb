# frozen_string_literal: true

# Public serving for first-class Pages (gumroad-private#1047): a seller's
# slugged pages, rendered at /<slug> on their username subdomain and custom
# domains. The profile itself (the root of the page tree) keeps rendering
# through UsersController#show.
#
# Two content types:
#
# - Rich text pages (written in the in-app editor) render server-side into a
#   minimal branded document — sanitized markup only, no seller scripts, so no
#   sandbox is needed.
# - Custom HTML pages (pushed by an agent or the CLI) render exactly like the
#   custom-HTML profile: a trusted wrapper page embedding the seller's HTML in
#   a sandboxed, strictly-CSP'd iframe served from /<slug>/landing/embed.
class UserPagesController < ApplicationController
  include CustomDomainConfig
  include RendersCustomHtmlPages

  before_action :stick_to_primary_for_landing_iframe, only: %i[landing_iframe_content landing_version]
  before_action :set_user_by_domain
  before_action :set_page

  def show
    if @page.custom_html.present?
      render html: page_custom_html_wrapper_document, layout: false
    else
      render html: rich_text_page_document, layout: false
    end
  end

  def landing_iframe_content
    return head :not_found unless @page.custom_html.present?

    apply_custom_html_response_headers
    interpolated = Pages::Interpolator.interpolate_profile(@page.custom_html, profile: @user)
    render html: <<~HTML.html_safe, layout: false
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          #{SANDBOX_COMPAT_SCRIPT}
          #{self.class.pages_tailwind_head}
        </head>
        <body>
          #{interpolated}
          #{custom_html_navigation_bridge_script(allowed_hostnames: page_store_hostnames)}
          #{FOLLOW_BRIDGE_SCRIPT}
        </body>
      </html>
    HTML
  end

  def landing_version
    visible = current_seller.present? && current_seller == @user && @page.custom_html.present?
    render_landing_version(visible:, page: visible ? @page : nil)
  end

  private
    def set_page
      @page = @user.pages.find_by(slug: params[:slug])
      e404 unless @page
    end

    def page_url
      "#{PROTOCOL}://#{request.host_with_port}/#{@page.slug}"
    end

    # Same shape as the profile's allowlist (see
    # UsersController#profile_store_hostnames): only hosts this seller controls,
    # so the sandboxed HTML can never navigate the visitor's tab to arbitrary
    # shared-host paths.
    def page_store_hostnames
      hostnames = []
      hostnames << request.host unless VALID_REQUEST_HOSTS.include?(request.host)
      hostnames << URI("#{PROTOCOL}://#{@user.subdomain}").host if @user.subdomain.present?
      hostnames << @user.custom_domain.domain if @user.custom_domain&.domain.present?
      hostnames.compact.uniq
    end

    def page_meta_head
      title = ERB::Util.h(@page.title.to_s)
      canonical = ERB::Util.h(page_url)
      <<~HTML
        <link rel="canonical" href="#{canonical}">
        <meta property="og:title" content="#{title}">
        <meta property="og:type" content="website">
        <meta property="og:url" content="#{canonical}">
      HTML
    end

    # Sanitized rich text renders directly — it can't carry scripts, so it
    # doesn't need the sandboxed-iframe pipeline. The document itself comes
    # from Pages::RichTextDocument, shared with the API's pull render.
    def rich_text_page_document
      profile_href = @is_user_custom_domain ? "/" : @user.profile_url
      Pages::RichTextDocument.render(page: @page, seller_name: @user.name_or_username, profile_href:, head_extra: page_meta_head)
    end

    # Mirrors UsersController#profile_custom_html_wrapper_document, scoped to a
    # single slugged page: same sandbox, same navigation bridge handshake, plus
    # the owner-only live reload used by the CLI preview loop.
    def page_custom_html_wrapper_document
      iframe_src = ERB::Util.h("/#{@page.slug}/landing/embed")
      title = ERB::Util.h(@page.title.to_s)
      store_hostnames_json = ERB::Util.json_escape(page_store_hostnames.to_json)
      nonce = SecureHeaders.content_security_policy_script_nonce(request)
      live_reload = if current_seller.present? && current_seller == @user
        custom_html_live_reload_script(version_src: "/#{@page.slug}/landing/version", nonce:)
      else
        ""
      end
      <<~HTML.html_safe
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            #{page_meta_head}
            <meta name="csrf-token" content="#{CsrfTokenInjector::TOKEN_PLACEHOLDER}">
            <style>html,body{margin:0;padding:0;height:100%;overflow:hidden}iframe{display:block;width:100%;height:100%;border:0}</style>
          </head>
          <body>
            <iframe
              id="gumroad-landing-frame"
              src="#{iframe_src}"
              title="#{title}"
              sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox"
            ></iframe>
            <script nonce="#{ERB::Util.h(nonce)}" data-cfasync="false">
              (function () {
                var frame = document.getElementById("gumroad-landing-frame");
                var STORE_HOSTNAMES = #{store_hostnames_json};
                window.addEventListener("message", function (e) {
                  if (!frame || e.source !== frame.contentWindow) return;
                  var d = e.data;
                  if (!d || d.type !== "gumroad:navigate" || typeof d.url !== "string") return;
                  var url;
                  try { url = new URL(d.url); } catch (_err) { return; }
                  if (url.protocol !== "https:" && url.protocol !== "http:") return;
                  if (STORE_HOSTNAMES.indexOf(url.hostname) === -1) return;
                  window.location.href = url.href;
                });
              })();
            </script>
            #{custom_html_follow_wrapper_script(seller_external_id: @user.external_id, nonce:)}
            #{live_reload}
          </body>
        </html>
      HTML
    end
end
