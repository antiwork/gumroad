# frozen_string_literal: true

class Admin::LinksController < Admin::BaseController
  before_action :fetch_product!, except: :show

  def show
    @product_matches = Link.where(id: params[:id]).or(Link.by_general_permalink(params["id"]))

    if @product_matches.many?
      @title = "Multiple products matched"
      render inertia: "Admin/Products/MultipleMatches", legacy_template: "admin/links/multiple_matches", props: {
        product_matches: @product_matches.map { |product| Admin::ProductPresenter::MultipleMatches.new(product:).props }
      }
    elsif @product_matches.one?
      @product = @product_matches.first
      @title = @product.name
      render inertia: "Admin/Products/Show", legacy_template: "admin/links/show", props: {
        title: @product.name,
        product: Admin::ProductPresenter::Card.new(product: @product, pundit_user:).props,
        user: Admin::UserPresenter::Card.new(user: @product.user, pundit_user:).props
      }
    else
      e404
    end
  end

  def destroy
    @product.delete!
    render json: { success: true }
  end

  def generate_url_redirect
    url_redirect = UrlRedirect.create!(link: @product)
    url_redirect.admin_generated = true
    url_redirect.save!

    redirect_to url_redirect.download_page_url
  end

  def restore
    render json: { success: @product.update_attribute(:deleted_at, nil) }
  end

  def publish
    begin
      @product.publish!
    rescue Link::LinkInvalid, WithProductFilesInvalid
      return render json: { success: false, error_message: @product.errors.full_messages.join(", ") }
    rescue => e
      Bugsnag.notify(e)
      return render json: { success: false, error_message: I18n.t(:error_500) }
    end

    render json: { success: true }
  end

  def unpublish
    @product.unpublish!

    render json: { success: true }
  end

  def is_adult
    @product.is_adult = params[:is_adult]
    @product.save!

    render json: { success: true }
  end

  def access_product_file
    url_redirect = @product.url_redirects.build
    product_file = ProductFile.find_by_external_id(params[:product_file_id])

    redirect_to url_redirect.signed_location_for_file(product_file), allow_other_host: true
  end

  def legacy_purchases
    product_id = params[:id].to_i
    product = Link.find_by(id: product_id)

    if parse_boolean(params[:is_affiliate_user])
      affiliate_user = User.find(params[:user_id])
      sales = Purchase.where(link_id: product_id, affiliate_id: affiliate_user.direct_affiliate_accounts.select(:id))
    else
      sales = product.sales
    end

    @purchases = sales.where("purchase_state IN ('preorder_authorization_successful', 'preorder_concluded_unsuccessfully', 'successful', 'failed', 'not_charged')").exclude_not_charged_except_free_trial
    @purchases = @purchases.order("created_at DESC, id DESC").page_with_kaminari(params[:page]).per(params[:per_page])

    respond_to do |format|
      purchases_json = @purchases.as_json(admin_review: true)
      format.json { render json: { purchases: purchases_json, page: params[:page].to_i } }
    end
  end

  def flag_seller_for_tos_violation
    product = Link.find_by(id: params[:id])
    user = product.user
    suspend_tos_reason = params.try(:[], :suspend_tos).try(:[], :reason) || params[:reason]
    raise "Invalid request" if user.nil? || !suspend_tos_reason
    raise "Cannot flag for TOS violation" if !user.can_flag_for_tos_violation?

    ActiveRecord::Base.transaction do
      user.update!(tos_violation_reason: suspend_tos_reason)
      comment_content = "Flagged for a policy violation on #{Time.current.to_fs(:formatted_date_full_month)} for a product named '#{product.name}' (#{suspend_tos_reason})"
      user.flag_for_tos_violation!(author_id: current_user.id, product_id: product.id, content: comment_content)
      unpublish_or_delete_product!(product)
    end

    render json: { success: true }
  rescue => e
    render json: { success: false, error_message: e.message }
  end

  def views_count
    if request.format.json?
      render json: { views_count: @product.number_of_views }
    else
      render layout: false
    end
  end

  def sales_stats
    if request.format.json?
      render json: {
        sales_stats: {
          preorder_state: @product.is_in_preorder_state,
          count: @product.is_in_preorder_state ? @product.sales.preorder_authorization_successful.count : @product.sales.successful.count,
          stripe_failed_count: @product.is_in_preorder_state ? @product.sales.preorder_authorization_failed.stripe_failed.count : @product.sales.stripe_failed.count,
          balance_formatted: @product.balance_formatted
        }
      }
    else
      render layout: false
    end
  end

  def join_discord
    integration = @product.get_integration(DiscordIntegration.name)
    return render plain: "No Discord integration found for this product." if integration.nil?

    discord_api = DiscordApi.new
    oauth_response = discord_api.oauth_token(params[:code], oauth_redirect_integrations_discord_index_url(host: DOMAIN, protocol: PROTOCOL))
    access_token = oauth_response.parsed_response&.dig("access_token")

    return render plain: "Failed to get access token from Discord, try re-authorizing." unless oauth_response.success? && access_token.present?

    begin
      user_response = discord_api.identify(access_token)
      user = JSON.parse(user_response)

      add_member_response = discord_api.add_member(integration.server_id, user["id"], access_token)
      return render plain: "Failed to join Discord Channel: #{integration.server_name}, please try again later." unless add_member_response.code === 201 || add_member_response.code === 204

      discord_redirect_uri = fetch_discord_redirect_uri(@product)
      return render plain: "Failed to get valid Discord Channel URI, please try again later." if discord_redirect_uri.nil?
      redirect_to discord_redirect_uri, allow_other_host: true
    rescue Discordrb::Errors::CodeError, Discordrb::Errors::NoPermission => e
      render plain: "Unexpected error response from Discord API: #{e.message}"
    end
  end

  def join_discord_redirect
    discord_oauth_url = "https://www.discord.com/api/oauth2/authorize"
    params = {
      "response_type" => "code",
      "redirect_uri" => oauth_redirect_integrations_discord_index_url(host: DOMAIN, protocol: PROTOCOL),
      "scope" => "identify guilds.join",
      "client_id" => DISCORD_CLIENT_ID,
      "state" => { is_admin: true, product_id: ObfuscateIds.encrypt(@product.id) }.to_json
    }
    redirect_uri = "#{discord_oauth_url}?#{params.to_query}"
    redirect_to(redirect_uri, allow_other_host: true)
  end

  private
    def fetch_product!
      @product = Link.find_by(id: params[:id])
      @product || e404
    end

    def unpublish_or_delete_product!(product)
      product.is_tiered_membership? ? product.unpublish! : product.delete!
    end

    def fetch_discord_redirect_uri(product)
      discord_integration = product.get_integration(DiscordIntegration.name)
      return nil if discord_integration.nil?

      begin
        URI.parse("https://discord.com/channels/#{discord_integration.server_id}/").to_s
      rescue URI::InvalidURIError
        nil
      end
    end

    def parse_boolean(value)
      value == "true" ? true : false
    end
end
