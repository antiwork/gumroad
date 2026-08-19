# frozen_string_literal: true

module Events
  def create_user_event(name, seller_id: nil, on_custom_domain: false)
    return if name.nil?

    create_event(
      event_name: name,
      on_custom_domain:,
      user_id: logged_in_user&.id
    )
  end

  def create_post_event(installment)
    @product = installment.try(:link)
    event = create_event(
      event_name: Event::NAME_POST_VIEW,
      user_id: logged_in_user&.id
    )
    installment_event = InstallmentEvent.new
    installment_event.installment_id = installment.id
    installment_event.event_id = event.id
    installment_event.save!
  end

  def create_purchase_event(purchase)
    create_event(
      billing_zip: purchase.zip_code,
      card_type: purchase.card_type,
      card_visual: purchase.card_visual,
      event_name: Event::NAME_PURCHASE,
      price_cents: purchase.price_cents,
      purchase_id: purchase.id,
      link_id: purchase.link.id,
      purchase_state: purchase.purchase_state,
      was_product_recommended: purchase.was_product_recommended?,
      referrer: purchase.referrer
    )
  end

  def create_service_charge_event(service_charge)
    create_event(
      billing_zip: service_charge.card_zip_code,
      card_type: service_charge.card_type,
      card_visual: service_charge.card_visual,
      event_name: Event::NAME_SERVICE_CHARGE,
      price_cents: service_charge.charge_cents,
      service_charge_id: service_charge.id,
      purchase_state: service_charge.state
    )
  end

  private
    def create_event(args)
      return if impersonating?

      event_class = case args[:event_name]
                    when "signup"
                      SignupEvent
                    else
                      Event
      end

      return if event_class == Event && Event::PERMITTED_NAMES.exclude?(args[:event_name]) && args[:user_id].nil?

      geo = GeoIp.lookup(request.remote_ip)
      referrer = args[:referrer] || Array.wrap(params[:referrer]).select(&:present?).last || request.referrer
      referrer = referrer.encode(Encoding.find("ASCII"), invalid: :replace, undef: :replace, replace: "") if referrer.present?
      referrer = referrer[0..190] if referrer.present?

      event = event_class.new
      event_params = {
        browser: request.env["HTTP_USER_AGENT"],
        browser_fingerprint: Digest::MD5.hexdigest([request.env["HTTP_USER_AGENT"], params[:plugins]].join(",")),
        browser_guid: cookies[:_gumroad_guid],
        extra_features: (args.delete(:extra_features) || {}).merge(
          browser: request.env["HTTP_USER_AGENT"],
          browser_plugins: params[:plugins],
          friend_actions: params[:friend],
          language: request.env["HTTP_ACCEPT_LANGUAGE"],
          source: params[:source],
          window_location: params[:window_location]
        ),
        from_multi_overlay: params[:from_multi_overlay],
        from_seo: seo_referrer?(session[:signup_referrer]),
        ip_address: request.remote_ip,
        ip_country: geo.try(:country_name),
        ip_state: geo.try(:region_name),
        ip_latitude: geo.try(:latitude).to_f,
        ip_longitude: geo.try(:longitude).to_f,
        is_mobile: is_mobile?,
        is_modal: params[:is_modal],
        link_id: @product.try(:id),
        parent_referrer: params[:parent_referrer],
        price_cents: @product.try(:price_cents),
        referrer:,
        referrer_domain: Referrer.extract_domain(referrer),
        view_url: params[:view_url] || request.env["PATH_INFO"],
        was_product_recommended: params[:was_product_recommended]
      }.merge(args)
      event_params.keys.each do |param|
        event_params.delete(param) unless event.respond_to?("#{param}=")
      end
      event.attributes = event_params
      if event.try(:was_product_recommended) && event.respond_to?(:referrer_domain=)
        event.referrer_domain = REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS
      end
      event.save!
      event
    end

    def seo_referrer?(referrer_domain)
      return unless referrer_domain.present?

      # Match end part of SEO domains (ie. google.com, www.google.com, yandex.ru, r.search.yahoo.com)
      referrer_domain.match?(/(google|bing|yahoo|yandex|duckduckgo)(\.[a-z]{2,3})(\.[a-z]{2})?$/i)
    end
end
