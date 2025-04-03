# frozen_string_literal: true

require "pagy/extras/limit"
require "pagy/extras/countless"
require "pagy/extras/array"
require "pagy/extras/overflow"
Pagy::DEFAULT[:overflow] = :exception
