# frozen_string_literal: true

# Work around a segfault during assets compilation
# https://github.com/sass/sassc-ruby/issues/207#issuecomment-674626874
Sprockets.export_concurrent = false
