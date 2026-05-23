# frozen_string_literal: true

module InertiaTestHelpers
  class InertiaRenderWrapper
    attr_reader :view_data, :props, :component

    def initialize(render_method)
      @render_method = render_method
    end

    def call(params)
      if params[:locals].present?
        @view_data = params[:locals].except(:page)
        @props = params[:locals][:page][:props]
        @component = params[:locals][:page][:component]
      else
        @view_data = {}
        json = JSON.parse(params[:json])
        @props = json["props"]
        @component = json["component"]
      end
      @render_method.call(params)
    end
  end

  def inertia
    @_inertia_render_wrapper
  end

  def expect_inertia
    expect(inertia)
  end

  def setup_inertia_renderer
    new_renderer = InertiaRails::Renderer.method(:new)
    allow(InertiaRails::Renderer).to receive(:new) do |component, controller, request, response, render, named_args|
      @_inertia_render_wrapper = InertiaRenderWrapper.new(render)
      new_renderer.call(component, controller, request, response, @_inertia_render_wrapper, **(named_args || {}))
    end
  end
end
