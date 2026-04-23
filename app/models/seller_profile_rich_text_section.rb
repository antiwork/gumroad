# frozen_string_literal: true

class SellerProfileRichTextSection < SellerProfileSection
  validate :limit_text_size

  private
    def limit_text_size
      errors.add(:base, "Text is too large") if text.to_json.length > 500_000
    end
end
