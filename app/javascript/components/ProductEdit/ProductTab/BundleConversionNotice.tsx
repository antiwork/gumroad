import * as React from "react";

import { Button, NavigationButton } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";

const BUNDLE_WORDS = ["bundle", "pack"];

export const BundleConversionNotice = () => {
  const { product, id } = useProductEditContext();

  const showNotice = BUNDLE_WORDS.some((word) => product.name.toLowerCase().includes(word.toLowerCase()));

  const [isModalOpen, setIsModalOpen] = React.useState(false);

  if (!showNotice || product.native_type === "membership" || product.variants.length) return null;

  return (
    <>
      <Alert role="status" variant="info">
        <div className="flex flex-col gap-4">
          <p>
            <strong>Có vẻ sản phẩm này có thể là một gói tuyệt vời!</strong> Với gói, khách hàng của bạn có thể truy cập
            nhiều sản phẩm cùng lúc với giá giảm, mà không cần sao chép nội dung hoặc quy trình làm việc.
          </p>
          <div>
            <Button color="primary" small onClick={() => setIsModalOpen(true)}>
              Chuyển sang gói
            </Button>
          </div>
        </div>
      </Alert>
      <Modal
        open={isModalOpen}
        onClose={() => setIsModalOpen(false)}
        title={`Transform "${product.name}" into a bundle?`}
        footer={
          <>
            <Button onClick={() => setIsModalOpen(false)}>Không, hủy</Button>
            <NavigationButton href={`${Routes.bundle_path(id)}/content`}>
              Có, hãy chọn sản phẩm
            </NavigationButton>
          </>
        }
      >
        <div className="flex flex-col gap-4">
          <div>
            <strong>
              Gói là một loại sản phẩm đặc biệt cho phép bạn cung cấp nhiều sản phẩm cùng nhau với giá giảm.
            </strong>{" "}
            Đây là những gì bạn có thể mong đợi khi chuyển đổi:
          </div>
          <ol>
            <li>Nội dung hiện tại của sản phẩm sẽ không còn chỉnh sửa được.</li>
            <li>Bạn sẽ chọn các sản phẩm để đưa vào gói mới.</li>
            <li>Sau khi lưu sản phẩm, khách hàng mới sẽ được truy cập các sản phẩm đã chọn.</li>
            <li>
              Khách hàng trước đây vẫn giữ quyền truy cập nội dung gốc. Họ sẽ không có quyền truy cập nội dung mới.
            </li>
            <li>Tất cả dữ liệu bán hàng của bạn sẽ được giữ nguyên.</li>
          </ol>
          <strong>Việc chuyển đổi không thể hoàn tác sau khi hoàn tất.</strong>
        </div>
      </Modal>
    </>
  );
};
