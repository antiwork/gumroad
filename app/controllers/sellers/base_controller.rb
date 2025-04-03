# frozen_string_literal: true

class Sellers::BaseController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized
end
