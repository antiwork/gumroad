# frozen_string_literal: true

class PageViewsController < ApplicationController
  def show
    user = resolve_seller
    # `user.alive?` covers the soft-deleted custom-domain path:
    # `Subdomain.find_seller_by_request` already filters on `User.alive`,
    # but `CustomDomain.find_by_host(...).user` resolves to whatever user
    # is on the CustomDomain row — and a CustomDomain is not auto-detached
    # when the owning user is soft-deleted. Without this guard the
    # deleted seller's pages would stay reachable via their old custom
    # domain.
    return head :not_found unless user&.alive?
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
