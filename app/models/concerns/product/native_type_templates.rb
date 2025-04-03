# frozen_string_literal: true

module Product::NativeTypeTemplates
  extend ActiveSupport::Concern

  DEFAULT_ATTRIBUTES_FOR_TYPE = {
    podcast: [
      { name: "Episodes", value: "" },
      { name: "Total length", value: "" }
    ],
    ebook: [
      { name: "Pages", value: "" }
    ],
    audiobook: [
      { name: "Length", value: "" }
    ],
  }.freeze

  PRODUCT_TYPES_THAT_INCLUDE_LAST_POST = ["membership", "newsletter"].freeze

  def set_template_properties_if_needed
    return if self.native_type.blank?

    save_custom_attributes(DEFAULT_ATTRIBUTES_FOR_TYPE[self.native_type.to_sym]) if DEFAULT_ATTRIBUTES_FOR_TYPE.key? self.native_type.to_sym
    self.should_include_last_post = true if PRODUCT_TYPES_THAT_INCLUDE_LAST_POST.include?(native_type)
  end
end
