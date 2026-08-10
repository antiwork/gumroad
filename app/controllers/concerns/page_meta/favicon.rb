# frozen_string_literal: true

module PageMeta::Favicon
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    # head_key matches set_default_meta_tags so this replaces the defaults
    # instead of appending a second icon link.
    def set_favicon_meta_tags(user)
      return unless user.avatar_url.present?

      set_meta_tag(tag_name: "link", rel: "shortcut icon", href: user.avatar_url, head_key: "shortcut-icon")
      set_meta_tag(tag_name: "link", rel: "apple-touch-icon", href: user.avatar_url, head_key: "apple-touch-icon")
    end
end
