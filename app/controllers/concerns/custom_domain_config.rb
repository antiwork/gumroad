# frozen_string_literal: true

module CustomDomainConfig
  def user_by_domain(host)
    user_by_subdomain(host) || user_by_custom_domain(host)
  end

  def set_user_and_custom_domain_config
    if GumroadDomainConstraint.matches?(request)
      set_user
    else
      set_user_by_domain

      @facebook_sdk_disabled = true
      @title = @user.try(:name_or_username)
      @body_class = "custom-domain"
    end
  end

  def product_by_custom_domain
    @_product_by_custom_domain ||= begin
      product = CustomDomain.find_by_host(request.host)&.product
      general_permalink = product&.general_permalink
      if general_permalink.blank?
        nil
      else
        Link.fetch_leniently(general_permalink, user: product.user)
      end
    end
  end

  def set_frontend_performance_sensitive
    @is_css_performance_sensitive = (logged_in_user != @user)
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
