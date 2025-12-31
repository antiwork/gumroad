# frozen_string_literal: true

InertiaRails.configure do |config|
  config.deep_merge_shared_data = true
  # Expose these Rails flash keys to the frontend via page.flash
  # Flash data accessed this way does NOT persist in browser history state
  config.flash_keys = %i[notice alert warning]
end
