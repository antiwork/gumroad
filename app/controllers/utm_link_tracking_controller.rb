# frozen_string_literal: true

class UtmLinkTrackingController < ApplicationController
  def show
    utm_link = UtmLink.active.find_by!(permalink: params[:permalink])

    e404 unless Feature.active?(:utm_links, utm_link.seller)

    redirect_to utm_link.utm_url, allow_other_host: true
  end
end
