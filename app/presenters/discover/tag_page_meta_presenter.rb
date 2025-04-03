# frozen_string_literal: true

class Discover::TagPageMetaPresenter
  include ActionView::Helpers::NumberHelper

  attr_reader :tags, :result_count

  def initialize(tags, result_count)
    @tags = tags
    @result_count = result_count
  end

  def title
    default_tag_title = fetch_discover_meta("titles.default", tags: tags.join(", "))
    return default_tag_title unless tags.one?

    fetch_discover_meta("titles.#{first_tag_key}", default: default_tag_title)
  end

  def meta_description
    tags_sentence = tags.to_sentence
    formatted_result_count = number_with_delimiter(result_count)
    default_description = fetch_discover_meta("descriptions.default", result_count: formatted_result_count,
                                                                      tags: tags_sentence)
    return default_description unless tags.one?

    fetch_discover_meta("descriptions.#{first_tag_key}", result_count: formatted_result_count,
                                                         default: default_description)
  end

  private
    def first_tag_key
      @first_tag_key ||= tags.first.squish.tr(" ", "-").downcase
    end

    def fetch_discover_meta(path, opts)
      default = opts.delete(:default) || ""
      str = DISCOVER_META_TAGS.dig(*(path.split(".")))

      return default if str.blank?

      str % opts
    end
end
