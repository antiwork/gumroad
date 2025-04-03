# frozen_string_literal: true

class Api::Internal::BaseController < ApplicationController
  skip_before_action :save_us_from_ddos
end
