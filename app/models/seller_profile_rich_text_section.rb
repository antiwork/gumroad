# frozen_string_literal: true

class SellerProfileRichTextSection < SellerProfileSection
  validate :limit_text_size
  after_save :trigger_iffy_ingest, if: -> { saved_change_to_json_data? || saved_change_to_header? }

  private
    def limit_text_size
      errors.add(:base, "Text is too large") if text.to_json.length > 500_000
    end

    def trigger_iffy_ingest
      Iffy::Profile::IngestJob.perform_async(seller_id)
    end
end
