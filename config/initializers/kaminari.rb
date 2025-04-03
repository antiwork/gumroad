# frozen_string_literal: true

# `will_paginate` is known to cause problems when used with `kaminari`
# This configuration file enables using `page_with_kaminari()` instead of `page()` when pagination via `kaminari` is desired
# Ref: https://github.com/kaminari/kaminari/issues/162#issuecomment-28673272

Kaminari.configure do |config|
  config.page_method_name = :page_with_kaminari
end
