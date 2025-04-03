# frozen_string_literal: true

# Chromedriver crashes when spawned with jemalloc in LD_PRELOAD.
# By the time Rails is booted, jemalloc is already linked and keeping it in ENV is not necessary.
ENV["LD_PRELOAD"] = ""
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
require "dotenv/load"

# silence warning "You can remove `require ‘dalli/cas/client’` as this code has been rolled into the standard ‘dalli/client’."
# TODO remove this when `suo` is updated
module Kernel
  alias_method :original_require, :require

  def require(name)
    original_require name if name != "dalli/cas/client"
  end
end
