# frozen_string_literal: true

# Serves a public demo's files under the grant ProductBuildDemosController#show issued. Like a buyer's
# player, but X may frame it, and there is no purchase to save to.
class ProductBuildDemoFilesController < ProductBuildPlayerFilesController
  private
    def grant_purpose = ProductBuild::PLAYER_DEMO_GRANT_PURPOSE

    # Also stops new page loads once the product is no longer free or on sale.
    def page_allowed? = ProductBuild.find_by(id: @grant["build_id"])&.demo?

    def frame_ancestors = ProductBuild::DEMO_FRAME_ANCESTORS

    def save_data = {}

    def save_endpoint = nil
end
