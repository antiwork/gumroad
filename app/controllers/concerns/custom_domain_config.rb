# frozen_string_literal: true

module CustomDomainConfig
  extend ActiveSupport::Concern

  include PageMeta::Base

  def user_by_domain(host)
    user_by_subdomain(host) || user_by_custom_domain(host)
  end

  def set_user_and_custom_domain_config
    if GumroadDomainConstraint.matches?(request)
      set_user
    else
      set_user_by_domain

      set_meta_tag(title: @user.try(:name_or_username))
      set_meta_tag(property: "gr:facebook_sdk:enabled", value: "false")
      if @user.enable_verify_domain_third_party_services? && @user.facebook_meta_tag.present?
        _, content = @user.facebook_meta_tag.match(/content="([^"]+)"/)
        set_meta_tag(name: "facebook-domain-verification", content:)
      end

      @body_class = "custom-domain"
    end
  end

  private
    def user_by_subdomain(host)
      @_user_by_subdomain ||= Subdomain.find_seller_by_hostname(host)
    end

    def user_by_custom_domain(host)
      CustomDomain.find_by_host(host).try(:user)
    end

    def set_user
      if params[:username]
        @user = User.find_by(username: params[:username]) ||
          User.find_by(external_id: params[:username])
      end

      error_if_user_not_found(@user)
    end

    def set_user_by_domain
      @user = user_by_domain(request.host)

      error_if_user_not_found(@user)
    end

    def error_if_user_not_found(user)
      unless user && user.account_active? && user.try(:username)
        respond_to do |format|
          format.html { e404 }
          format.json { return e404_json }
          format.xml  { return e404_xml }
          format.any  { e404 }
        end
      end
    end
end
