# frozen_string_literal: true

class UtmLinkTrackingController < ApplicationController
  def show
    utm_link = UtmLink.active.find_by!(permalink: params[:permalink])
    url = utm_link.utm_url

    # utm_url is nil when the target product/post was hard-deleted (e.g. GDPR erasure)
    # after the short link was already distributed; redirect_to(nil) raises.
    return render plain: "This link's destination is no longer available.", status: :not_found if url.nil?

    redirect_to url, allow_other_host: true
  end
end
