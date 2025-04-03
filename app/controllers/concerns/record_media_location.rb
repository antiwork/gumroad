# frozen_string_literal: true

module RecordMediaLocation
  private
    def record_media_location(params)
      return false if params[:url_redirect_id].blank? || params[:product_file_id].blank? || params[:location].blank?

      url_redirect_id = ObfuscateIds.decrypt(params[:url_redirect_id])
      purchase_id = params[:purchase_id].present? ? ObfuscateIds.decrypt(params[:purchase_id]) : UrlRedirect.find(url_redirect_id).try(:purchase).try(:id)
      product_id = Purchase.find_by(id: purchase_id).try(:link).try(:id)
      return false if product_id.blank? || purchase_id.blank?

      consumed_at = params[:consumed_at].present? ? Time.zone.parse(params[:consumed_at]) : Time.current
      product_file = ProductFile.find(ObfuscateIds.decrypt(params[:product_file_id]))
      return false unless product_file.consumable?

      media_location = MediaLocation.find_or_initialize_by(url_redirect_id:,
                                                           purchase_id:,
                                                           product_file_id: product_file.id,
                                                           product_id:,
                                                           platform: params[:platform])
      return false unless media_location.new_record? || consumed_at > media_location.consumed_at

      media_location.update!(location: params[:location], consumed_at:)

      true
    end
end
