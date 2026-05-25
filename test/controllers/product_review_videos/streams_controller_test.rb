# frozen_string_literal: true

require "test_helper"

class ProductReviewVideos::StreamsControllerTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers

  SMIL_XML = '<smil><body><switch><video src="sample.mp4" /></switch></body></smil>'

  setup do
    @prv = product_review_videos(:named_seller_product_review_video)
    @video_file = video_files(:named_seller_product_review_video_file)
  end

  test "returns smil content when format is smil" do
    @video_file.define_singleton_method(:smil_xml) { SMIL_XML }
    # Stub VideoFile.find / association lookup to return our instance.
    target = @video_file
    VideoFile.singleton_class.send(:define_method, :__test_target) { target }
    # `smil_xml` is defined directly on VideoFile — capture+restore the
    # UnboundMethod so `remove_method` doesn't strip the real implementation
    # and leak NoMethodError into sibling tests.
    orig_smil = VideoFile.instance_method(:smil_xml) if VideoFile.method_defined?(:smil_xml)
    begin
      VideoFile.define_method(:smil_xml) { SMIL_XML }
      get :show, params: { product_review_video_id: @prv.external_id, format: :smil }
      assert_response :success
      assert_includes response.content_type, "application/smil+xml"
      assert_equal SMIL_XML, response.body
    ensure
      if orig_smil
        VideoFile.define_method(:smil_xml, orig_smil)
      elsif VideoFile.instance_methods(false).include?(:smil_xml)
        VideoFile.remove_method(:smil_xml)
      end
      VideoFile.singleton_class.send(:remove_method, :__test_target)
    end
  end

  test "returns 406 for non-smil formats" do
    assert_raises(ActionController::UnknownFormat) do
      get :show, params: { product_review_video_id: @prv.external_id, format: :html }
    end
  end

  test "returns 406 when no format is specified" do
    assert_raises(ActionController::UnknownFormat) do
      get :show, params: { product_review_video_id: @prv.external_id }
    end
  end

  test "returns 404 for non-existent video" do
    assert_raises(ActiveRecord::RecordNotFound) do
      get :show, params: { product_review_video_id: "non-existent-id", format: :smil }
    end
  end

  test "returns 404 for soft deleted video" do
    @prv.mark_deleted!
    assert_raises(ActiveRecord::RecordNotFound) do
      get :show, params: { product_review_video_id: @prv.external_id, format: :smil }
    end
  end
end
