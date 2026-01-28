# frozen_string_literal: true

module PageMeta::Favicon
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    def set_favicon_meta_tags(user)
      return unless user.avatar_url.present?

      set_meta_tag(tag_name: "link", rel: "shortcut icon", href: user.avatar_url)
      remove_meta_tag("apple-touch-icon")
    end
end
