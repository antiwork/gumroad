# frozen_string_literal: true

# See https://github.com/shakacode/react_on_rails/blob/master/docs/basics/configuration.md
# for many more options.

module RenderingExtension
  extend self

  def custom_context(view_context)
    pundit_user = view_context.pundit_user
    {
      design_settings: { font: { name: "ABC Favorit", url: view_context.font_url("ABCFavorit-Regular.woff2") } },
      domain_settings: {
        scheme: PROTOCOL,
        app_domain: DOMAIN,
        root_domain: ROOT_DOMAIN,
        short_domain: SHORT_DOMAIN,
        discover_domain: DISCOVER_DOMAIN,
        third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
        api_domain: API_DOMAIN,
      },
      user_agent_info: {
        is_mobile: view_context.controller.is_mobile?,
      },
      logged_in_user: logged_in_user_props(pundit_user, is_impersonating: view_context.controller.impersonating?),
      current_seller: current_seller_props(pundit_user),
      csp_nonce: SecureHeaders.content_security_policy_script_nonce(view_context.request),
      locale: view_context.controller.http_accept_language.user_preferred_languages[0] || "en-US",
      feature_flags: {
        require_email_typo_acknowledgment: Feature.active?(:require_email_typo_acknowledgment),
      }
    }
  end

  private
    def logged_in_user_props(pundit_user, is_impersonating:)
      user = pundit_user.user
      return nil unless user

      {
        id: user.external_id,
        email: user.email,
        name: user.name,
        avatar_url: user.avatar_url,
        confirmed: user.confirmed?,
        team_memberships: UserMembershipsPresenter.new(pundit_user:).props,
        policies: policies_props(pundit_user),
        is_gumroad_admin: user.is_team_member?,
        is_impersonating:
      }
    end

    # Policies accessible via loggedInUser
    # Only used for policies that don't need record-specific logic, like LinkPolicy::edit? where a product record is required
    # Policies should be grouped by Policy class name
    # Naming convention:
    # - policy class key: Settings::Payments::UserPolicy.name.underscore.tr("/", "_").gsub(/(_policy)$/, "")
    # - policy method key: Settings::Payments::UserPolicy.instance_methods(false).first.to_s.chop
    #
    def policies_props(pundit_user)
      {
        affiliate_requests_onboarding_form: {
          update: Pundit.policy!(pundit_user, [:affiliate_requests, :onboarding_form]).update?,
        },
        direct_affiliate: {
          create: Pundit.policy!(pundit_user, DirectAffiliate).create?,
          update: Pundit.policy!(pundit_user, DirectAffiliate).update?,
        },
        collaborator: {
          create: Pundit.policy!(pundit_user, Collaborator).create?,
          update: Pundit.policy!(pundit_user, Collaborator).update?,
        },
        product: {
          create: Pundit.policy!(pundit_user, Link).create?,
        },
        product_review_response: {
          update: Pundit.policy!(pundit_user, ProductReviewResponse).update?,
        },
        balance: {
          index: Pundit.policy!(pundit_user, :balance).index?,
          export: Pundit.policy!(pundit_user, :balance).export?,
        },
        checkout_offer_code: {
          create: Pundit.policy!(pundit_user, [:checkout, OfferCode]).create?,
        },
        checkout_form: {
          update: Pundit.policy!(pundit_user, [:checkout, :form]).update?,
        },
        upsell: {
          create: Pundit.policy!(pundit_user, [:checkout, Upsell]).create?,
        },
        settings_payments_user: {
          show: Pundit.policy!(pundit_user, [:settings, :payments, pundit_user.seller]).show?,
        },
        settings_profile: {
          manage_social_connections: Pundit.policy!(pundit_user, [:settings, :profile]).manage_social_connections?,
          update: Pundit.policy!(pundit_user, [:settings, :profile]).update?,
          update_username: Pundit.policy!(pundit_user, [:settings, :profile]).update_username?
        },
        settings_third_party_analytics_user: {
          update: Pundit.policy!(pundit_user, [:settings, :third_party_analytics, pundit_user.seller]).update?
        },
        installment: {
          create: Pundit.policy!(pundit_user, Installment).create?,
        },
        workflow: {
          create: Pundit.policy!(pundit_user, Workflow).create?,
        },
        utm_link: {
          index: Pundit.policy!(pundit_user, :utm_link).index?,
        },
        community: {
          index: Pundit.policy!(pundit_user, Community).index?,
        }
      }
    end

    def current_seller_props(pundit_user)
      seller = pundit_user.seller
      return nil unless seller

      UserPresenter.new(user: pundit_user.seller).as_current_seller
    end
end

ReactOnRails.configure do |config|
  # This configures the script to run to build the production assets by webpack. Set this to nil
  # if you don't want react_on_rails building this file for you.
  # If nil, then the standard shakacode/shakapacker assets:precompile will run
  # config.build_production_command = nil

  ################################################################################
  ################################################################################
  # TEST CONFIGURATION OPTIONS
  # Below options are used with the use of this test helper:
  # ReactOnRails::TestHelper.configure_rspec_to_compile_assets(config)
  ################################################################################

  # If you are using this in your spec_helper.rb (or rails_helper.rb):
  #
  # ReactOnRails::TestHelper.configure_rspec_to_compile_assets(config)
  #
  # with rspec then this controls what yarn command is run
  # to automatically refresh your webpack assets on every test run.
  #
  # Alternately, you can remove the `ReactOnRails::TestHelper.configure_rspec_to_compile_assets`
  # and set the config/shakapacker.yml option for test to true.
  config.build_test_command = "RAILS_ENV=test bin/shakapacker"

  ################################################################################
  ################################################################################
  # SERVER RENDERING OPTIONS
  ################################################################################
  # This is the file used for server rendering of React when using `(prerender: true)`
  # If you are never using server rendering, you should set this to "".
  # Note, there is only one server bundle, unlike JavaScript where you want to minimize the size
  # of the JS sent to the client. For the server rendering, React on Rails creates a pool of
  # JavaScript execution instances which should handle any component requested.
  #
  # While you may configure this to be the same as your client bundle file, this file is typically
  # different. You should have ONE server bundle which can create all of your server rendered
  # React components.
  #
  config.server_bundle_js_file = "js/ssr.js"

  config.rendering_extension = RenderingExtension
end

module ReactOnRails::Helper
  alias_method :original_react_component, :react_component
  def react_component(name, opts = {})
    opts[:html_options] ||= {}
    opts[:html_options][:class] = "react-entry-point"
    opts[:html_options][:style] = "display:contents"
    opts[:request] = request
    original_react_component(name, opts)
  end

  alias_method :original_internal_react_component, :internal_react_component
  def internal_react_component(*args)
    result = original_internal_react_component(*args)
    if result[:result]["redirect"]
      controller.redirect_to result[:result]["redirect"]
    end
    html = result[:result]["html"]
    if html.end_with? "</script>"
      html.insert(html.rindex("<script") + 7, " data-cfasync=\"false\"")
    end
    nonce = SecureHeaders.content_security_policy_script_nonce(request)
    # react-on-rails does not provide a way to set a nonce
    replay = result[:result]["consoleReplayScript"]
    replay["<script"] = "<script nonce='#{nonce}'" if replay.present?
    result
  end
end

module ReactOnRails
  module ServerRenderingJsCode
    class << self
      def render(props_string, rails_context, _, react_component_name, _)
        # This is mostly copied from the original, with additions to handle Promises, the fetch wrapper,
        # and to pass additional options.
        <<-JS
        (function() {
          Response.prototype.body = "";
          globalThis.fetch = (url, settings) => {
            const res = _fetch(url, settings);
            return new Response(res.body, res);
          };
          return ReactOnRails.serverRenderReactComponent({
            name: '#{react_component_name}',
            props: #{props_string},
            railsContext: #{rails_context},
            renderingReturnsPromises: true,
            throwJsErrors: true,
          });
        })().then(
          (res) => finish(JSON.stringify(res)),
          (e) => {
            if (e instanceof Response) finish(JSON.stringify({ redirect: e.headers.get("Location"), consoleReplayScript: "", html: "" }));
            else finish(JSON.stringify({ __error: e.stack }));
          })
        JS
      end
    end
  end
end

class ReactRuntime < ExecJS::MiniRacerRuntime
  class Context < ExecJS::MiniRacerRuntime::Context
    def initialize(*args)
      super
      @context.attach "_fetch", proc { |url, settings|
        # We intercept the frontend's calls to `fetch` and call the controllers here directly
        uri = URI.parse(url)
        url = "#{UrlService.domain_with_protocol}#{url}" if uri.is_a? URI::Generic
        query_params = Rack::Utils.parse_nested_query(uri.query)
        res = Rails.application.routes.recognize_path(url, method: settings["method"])
        response = ActionDispatch::Response.create
        controller = "#{res[:controller].camelize}Controller".constantize.new
        controller.request = @request
        controller.response = response
        params = res
        params = params.merge(settings["body"]) if settings["body"].is_a? Hash
        params = params.merge(query_params)
        controller.params = params
        controller.process(res[:action])
        { body: response.body, status: response.status, headers: response.headers }
      }
      @context.attach "finish", proc { |value| @value = value }
      # Once the bundle has been evaluated, we monkey-patch the eval method to handle Promises instead.
      # Since mini-racer does not provide any native promise handling, we simply spin-wait until we've received a response.
      class << self
        def eval(code, options)
          @value = nil
          @request = options.internal_option(:request)
          original_eval(code)
          1000.times do
            sleep 0.005 unless @value
          end
          if @value
            json = JSON.parse(@value)
            raise StandardError, json["__error"] if json["__error"]
          end
          @value
        end
      end
    end

    alias_method :original_eval, :eval
  end
end

module ReactOnRails::ServerRenderingPool
  # Monkey-patch a replacement for ExecJS into ReactOnRails so we don't have to modify it globally
  ExecJS = ReactRuntime.new

  class RubyEmbeddedJavaScript
    # Copied from the original, but passes through the options.
    class << self
      def eval_js(js_code, render_options)
        @js_context_pool.with do |js_context|
          js_context.eval(js_code, render_options)
        end
      end
    end
  end
end
