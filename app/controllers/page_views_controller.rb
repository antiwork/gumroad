# frozen_string_literal: true

class PageViewsController < ApplicationController
  def show
    user = resolve_seller
    return head :not_found unless user
    return head :not_found if user.suspended?

    page = user.pages.alive.published.find_by!(slug: params[:slug])
    # A published row without a pinned version means there is nothing safe to
    # serve publicly — falling back to html_content would leak the seller's
    # working draft. publish! guards against this on the write path, but the
    # check here is the read-side belt-and-suspenders.
    return head :not_found if page.published_version.nil?

    render inertia: "Pages/Show", props: {
      page: {
        title: page.title,
        html_content: page.published_version.html,
        slug: page.slug,
        seller: {
          name: user.display_name,
          username: user.username,
          avatar_url: user.avatar_url,
        },
      },
    }
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private
    def resolve_seller
      return User.alive.find_by(username: params[:username]) if params[:username].present?

      Subdomain.find_seller_by_request(request) ||
        CustomDomain.find_by_host(request.host)&.user
    end
end
