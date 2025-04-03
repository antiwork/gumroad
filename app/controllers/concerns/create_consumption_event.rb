# frozen_string_literal: true

module CreateConsumptionEvent
  private
    def create_consumption_event!(params)
      return false if params[:url_redirect_id].blank? || ConsumptionEvent::EVENT_TYPES.exclude?(params[:event_type])

      url_redirect_id = ObfuscateIds.decrypt(params[:url_redirect_id])
      product_file_id = ObfuscateIds.decrypt(params[:product_file_id]) if params[:product_file_id].present?
      purchase_id = params[:purchase_id].present? ? ObfuscateIds.decrypt(params[:purchase_id]) : UrlRedirect.find(url_redirect_id)&.purchase_id
      product_id = Purchase.find_by(id: purchase_id)&.link_id
      consumed_at = params[:consumed_at].present? ? Time.zone.parse(params[:consumed_at]) : Time.current

      ConsumptionEvent.create_event!(
        event_type: params[:event_type],
        platform: params[:platform],
        url_redirect_id:,
        product_file_id:,
        purchase_id:,
        product_id:,
        consumed_at:,
        ip_address: request.remote_ip,
      )
      true
    end
end
