# frozen_string_literal: true

class Settings::ThirdPartyAnalyticsController < Settings::BaseController
  before_action :authorize

  def show
    render inertia: "Settings/ThirdPartyAnalytics/Show", props: {
      third_party_analytics: settings_presenter.third_party_analytics_props,
      meta_conversions: settings_presenter.meta_conversions_props,
      products: current_seller.links.alive.map { |product| { permalink: product.unique_permalink, name: product.name } }
    }
  end

  def update
    current_seller.with_lock do
      current_seller.assign_attributes(third_party_analytics_params.except(:snippets))
      ThirdPartyAnalytic.save_third_party_analytics(third_party_analytics_params[:snippets] || [], current_seller)

      if current_seller.save
        save_meta_conversions_access_token
        redirect_to settings_third_party_analytics_path, status: :see_other, notice: "Changes saved!"
      else
        redirect_to settings_third_party_analytics_path, alert: current_seller.errors.full_messages.to_sentence
      end
    end
  rescue ThirdPartyAnalytic::ThirdPartyAnalyticInvalid => e
    redirect_to settings_third_party_analytics_path, alert: e.message
  rescue StandardError => e
    ErrorNotifier.notify(e)
    redirect_to settings_third_party_analytics_path, alert: "Something broke. We're looking into what happened. Sorry about this!"
  end

  private
    def third_party_analytics_params
      params.require(:user).permit(
        :disable_third_party_analytics,
        :google_analytics_id,
        :facebook_pixel_id,
        :tiktok_pixel_id,
        :skip_free_sale_analytics,
        :enable_verify_domain_third_party_services,
        :facebook_meta_tag,
        snippets: [[:id, :code, :location, :name, :product]],
      )
    end

    def save_meta_conversions_access_token
      return unless Feature.active?(:meta_conversions_api, current_seller)

      # Removal wins: the page can send a typed replacement along with the flag.
      if ActiveModel::Type::Boolean.new.cast(params.dig(:user, :remove_meta_conversions_access_token))
        current_seller.meta_conversions_setting&.destroy!
        return
      end

      access_token = params.dig(:user, :meta_conversions_access_token).to_s.strip
      if access_token.present?
        setting = current_seller.meta_conversions_setting || current_seller.build_meta_conversions_setting
        setting.update!(access_token:, token_rejected_at: nil)
      end
    end

    def authorize
      super([:settings, :third_party_analytics, current_seller])
    end
end
