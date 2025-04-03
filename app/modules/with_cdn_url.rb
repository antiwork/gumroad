# frozen_string_literal: true

module WithCdnUrl
  include CdnUrlHelper

  extend ActiveSupport::Concern

  module ClassMethods
    def has_cdn_url(*attributes)
      attributes.each do |attribute|
        define_method attribute do
          replace_s3_urls_with_cdn_urls(self.attributes[attribute.to_s])
        end
      end
    end
  end
end
