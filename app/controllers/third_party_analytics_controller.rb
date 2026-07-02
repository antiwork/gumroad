# frozen_string_literal: true

class ThirdPartyAnalyticsController < ApplicationController
  before_action { opt_out_of_header(:csp) } # Turn off CSP for this controller
  before_action :fetch_product, except: :profile

  OVERRIDE_WINDOW_ACTIONS_CODE = "<script type=\"text/javascript\">
try { window.alert = function() {}; } catch(error) { }
try { window.confirm = function() {}; } catch(error) { }
try { window.prompt = function() {}; } catch(error) { }
try { window.print = function() {}; } catch(error) { }
</script>"

  OVERRIDE_ON_CLOSE_CODE = "<script type=\"text/javascript\">
try { window.onbeforeunload = null; } catch(error) { }
try { window.onabort = null; } catch(error) { }
</script>"

  after_action :erase_cookies_and_skip_session

  def index
    @third_party_analytics = OVERRIDE_WINDOW_ACTIONS_CODE
    product_snippets = @product.third_party_analytics.alive.where(location: [params[:location], "all"]).pluck(:analytics_code)
    @third_party_analytics += product_snippets.join("\n") if product_snippets.present?
    user_snippets = @product.user.third_party_analytics.universal.alive.where(location: [params[:location], "all"]).pluck(:analytics_code)
    @third_party_analytics += user_snippets.join("\n") if user_snippets.present?
    @third_party_analytics += OVERRIDE_ON_CLOSE_CODE

    if params[:purchase_id].present?
      currency = @product.price_currency_type
      purchase = @product.sales.find_by_external_id(params[:purchase_id])

      # the purchase was just created and may not be in the read replicas so look in master
      if purchase.nil?
        ActiveRecord::Base.connection.stick_to_primary!
        purchase = @product.sales.find_by_external_id(params[:purchase_id])
      end

      e404 if purchase.nil?

      price = Money.new(purchase.displayed_price_cents, currency.to_sym).format(no_cents_if_whole: true, symbol: false)

      @third_party_analytics.gsub!("$VALUE", price)
      @third_party_analytics.gsub!("$CURRENCY", currency.upcase)
      @third_party_analytics.gsub!("$ORDER", params[:purchase_id])
    end

    render layout: false
  end

  # Serves the seller's universal raw snippets for the profile page (#5676),
  # which has no product to hang the permalink-based index action on. Only
  # "all"-located universal snippets run here: "product"/"receipt" scope a
  # snippet to the purchase flow, and there is no purchase context for the
  # $VALUE/$CURRENCY/$ORDER substitutions either.
  def profile
    user = User.alive.find_by(username: params[:username])
    return e404 if user.nil?

    @third_party_analytics = OVERRIDE_WINDOW_ACTIONS_CODE
    snippets = user.third_party_analytics.universal.alive.where(location: "all").pluck(:analytics_code)
    @third_party_analytics += snippets.join("\n") if snippets.present?
    @third_party_analytics += OVERRIDE_ON_CLOSE_CODE

    render :index, layout: false
  end

  private
    def erase_cookies_and_skip_session
      request.session_options[:skip] = true
      cookies.clear
    end
end
