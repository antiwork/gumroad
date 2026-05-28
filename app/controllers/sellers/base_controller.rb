# frozen_string_literal: true

class Sellers::BaseController < ApplicationController
  include RequireAccountEmail

  before_action :authenticate_user!
  after_action :verify_authorized
end
