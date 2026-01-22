import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { useProductUrl } from "$app/components/ProductEdit/Layout";
import { Version, useProductEditContext } from "$app/components/ProductEdit/state";
import { Drawer, ReorderingHandle, SortableList } from "$app/components/SortableList";
import { Toggle } from "$app/components/Toggle";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Row, RowActions, RowContent, RowDetails, Rows } from "$app/components/ui/Rows";
import { WithTooltip } from "$app/components/WithTooltip";

let newVersionId = 0;

export const VersionsEditor = ({
  versions,
  onChange,
}: {
  versions: Version[];
  onChange: (versions: Version[]) => void;
}) => {
  const updateVersion = (id: string, update: Partial<Version>) => {
    onChange(versions.map((version) => (version.id === id ? { ...version, ...update } : version)));
  };

  const [deletionModalVersionId, setDeletionModalVersionId] = React.useState<string | null>(null);
  const deletionModalVersion = versions.find(({ id }) => id === deletionModalVersionId);

  const addButton = (
    <Button
      color="primary"
      onClick={() => {
        onChange([
          ...versions,
          {
            id: (newVersionId++).toString(),
            name: "Chưa đặt tên",
            description: "",
            price_difference_cents: 0,
            max_purchase_count: null,
            integrations: {
              discord: false,
              circle: false,
              google_calendar: false,
            },
            newlyAdded: true,
            rich_content: [],
          },
        ]);
      }}
    >
      <Icon name="plus" />
      Thêm phiên bản
    </Button>
  );

  return versions.length === 0 ? (
    <Placeholder>
      <h2>Cung cấp các biến thể của sản phẩm này</h2>
      Thu hút khách hàng với các tùy chọn định dạng, phiên bản khác nhau, v.v.
      {addButton}
    </Placeholder>
  ) : (
    <>
      {deletionModalVersion ? (
        <Modal
          open={!!deletionModalVersion}
          onClose={() => setDeletionModalVersionId(null)}
          title={`Remove ${deletionModalVersion.name}?`}
          footer={
            <>
              <Button onClick={() => setDeletionModalVersionId(null)}>Không, hủy</Button>
              <Button
                color="accent"
                onClick={() => onChange(versions.filter(({ id }) => id !== deletionModalVersion.id))}
              >
                Có, xóa
              </Button>
            </>
          }
        >
          Nếu bạn xóa phiên bản này, nội dung liên quan cũng sẽ bị xóa. Khách hàng hiện tại đã mua sẽ thấy nội dung
          từ phiên bản rẻ nhất hiện tại làm dự phòng. Nếu không có phiên bản nào, họ sẽ thấy nội dung cấp sản phẩm.
        </Modal>
      ) : null}
      <SortableList
        currentOrder={versions.map(({ id }) => id)}
        onReorder={(newOrder) =>
          onChange(newOrder.flatMap((id) => versions.find((version) => version.id === id) ?? []))
        }
        tag={SortableVersionEditors}
      >
        {versions.map((version) => (
          <VersionEditor
            key={version.id}
            version={version}
            updateVersion={(update) => updateVersion(version.id, update)}
            onDelete={() => setDeletionModalVersionId(version.id)}
          />
        ))}
      </SortableList>
      {addButton}
    </>
  );
};

const VersionEditor = ({
  version,
  updateVersion,
  onDelete,
}: {
  version: Version;
  updateVersion: (update: Partial<Version>) => void;
  onDelete: () => void;
}) => {
  const uid = React.useId();
  const { product, currencyType } = useProductEditContext();

  const [isOpen, setIsOpen] = React.useState(true);

  const url = useProductUrl({ option: version.id });

  const integrations = Object.entries(product.integrations)
    .filter(([_, enabled]) => enabled)
    .map(([name]) => name);

  return (
    <Row role="listitem">
      <RowContent>
        <ReorderingHandle />
        <Icon name="stack-fill" />
        <h3>{version.name || "Untitled"}</h3>
      </RowContent>
      <RowActions>
        <WithTooltip tip={isOpen ? "Đóng" : "Mở"}>
          <Button onClick={() => setIsOpen((prevIsOpen) => !prevIsOpen)}>
            <Icon name={isOpen ? "outline-cheveron-up" : "outline-cheveron-down"} />
          </Button>
        </WithTooltip>
        <WithTooltip tip="Xóa">
          <Button onClick={onDelete} aria-label="Xóa phiên bản">
            <Icon name="trash2" />
          </Button>
        </WithTooltip>
      </RowActions>
      {isOpen ? (
        <RowDetails asChild>
          <Drawer className="grid gap-6">
            <fieldset>
              <label htmlFor={`${uid}-name`}>Tên</label>
              <div className="input">
                <input
                  id={`${uid}-name`}
                  type="text"
                  value={version.name}
                  placeholder="Tên phiên bản"
                  onChange={(evt) => updateVersion({ name: evt.target.value })}
                />
                <a href={url} target="_blank" rel="noreferrer">
                  Chia sẻ
                </a>
              </div>
            </fieldset>
            <fieldset>
              <label htmlFor={`${uid}-description`}>Mô tả</label>
              <textarea
                id={`${uid}-description`}
                value={version.description}
                onChange={(evt) => updateVersion({ description: evt.target.value })}
              />
            </fieldset>
            <section className="grid grid-flow-col items-end gap-6">
              <fieldset>
                <label htmlFor={`${uid}-price`}>Số tiền bổ sung</label>
                <PriceInput
                  id={`${uid}-price`}
                  currencyCode={currencyType}
                  cents={version.price_difference_cents}
                  onChange={(price_difference_cents) => updateVersion({ price_difference_cents })}
                  placeholder="0"
                />
              </fieldset>
              <fieldset>
                <label htmlFor={`${uid}-max-purchase-count`}>Số lượng mua tối đa</label>
                <NumberInput
                  onChange={(value) => updateVersion({ max_purchase_count: value })}
                  value={version.max_purchase_count}
                >
                  {(inputProps) => (
                    <input id={`${uid}-max-purchase-count`} type="number" placeholder="∞" {...inputProps} />
                  )}
                </NumberInput>
              </fieldset>
            </section>
            {integrations.length > 0 ? (
              <fieldset>
                <legend>Tích hợp</legend>
                {integrations.map((integration) => (
                  <Toggle
                    value={version.integrations[integration]}
                    onChange={(enabled) =>
                      updateVersion({ integrations: { ...version.integrations, [integration]: enabled } })
                    }
                    key={integration}
                  >
                    {integration === "circle" ? "Cho phép truy cập cộng đồng Circle" : "Cho phép truy cập máy chủ Discord"}
                  </Toggle>
                ))}
              </fieldset>
            ) : null}
          </Drawer>
        </RowDetails>
      ) : null}
    </Row>
  );
};

export const SortableVersionEditors = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ children }, ref) => (
    <Rows ref={ref} role="list" aria-label="Version editor">
      {children}
    </Rows>
  ),
);
SortableVersionEditors.displayName = "SortableVersionEditors";
