import hands from "images/illustrations/hands.png";
import * as React from "react";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { Layout, useProductUrl } from "$app/components/ProductEdit/Layout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { Toggle } from "$app/components/Toggle";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Alert } from "$app/components/ui/Alert";
import { useRunOnce } from "$app/components/useRunOnce";

export const ShareTab = () => {
  const currentSeller = useCurrentSeller();

  const { id, product, updateProduct, profileSections, taxonomies, isListedOnDiscover } = useProductEditContext();

  const url = useProductUrl();
  const discoverUrl = useDiscoverUrl();

  if (!currentSeller) return;
  const discoverLink = new URL(discoverUrl);
  discoverLink.searchParams.set("query", product.name);

  return (
    <Layout preview={<ProductPreview />}>
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <DiscoverEligibilityPromo />
            <header>
              <h2>Chia sẻ</h2>
            </header>
            <div className="flex flex-wrap gap-2">
              <TwitterShareButton url={url} text={`Buy ${product.name} on @Gumroad`} />
              <FacebookShareButton url={url} text={product.name} />
              <CopyToClipboard text={url} tooltipPosition="top">
                <Button color="primary">
                  <Icon name="link" />
                  Sao chép URL
                </Button>
              </CopyToClipboard>
              <NavigationButton
                href={`https://gum.new?productId=${id}`}
                target="_blank"
                rel="noopener noreferrer"
                color="accent"
              >
                <Icon name="plus" />
                Tạo Gum
              </NavigationButton>
            </div>
          </section>
          <ProfileSectionsEditor
            sectionIds={product.section_ids}
            onChange={(sectionIds) => updateProduct({ section_ids: sectionIds })}
            profileSections={profileSections}
          />
          <section className="p-8!">
            <header style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <h2>Gumroad Discover</h2>
              <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
                Tìm hiểu thêm
              </a>
            </header>
            {isListedOnDiscover ? (
              <Alert role="status" variant="success">
                <div className="flex flex-col justify-between sm:flex-row">
                  {product.name} đã được niêm yết trên Gumroad Discover.
                  <a href={discoverLink.toString()}>Xem</a>
                </div>
              </Alert>
            ) : null}
            <div className="flex flex-col gap-4">
              <p>
                Gumroad Discover giới thiệu sản phẩm của bạn cho khách hàng tiềm năng với mức phí cố định 30% trên mỗi lần bán,
                giúp bạn phát triển vượt ra ngoài lượng người theo dõi hiện có và tìm thấy nhiều người quan tâm đến công việc của bạn.
              </p>
              <p>Khi được bật, sản phẩm cũng sẽ trở thành một phần của chương trình tiếp thị liên kết Gumroad.</p>
            </div>
            <TaxonomyEditor
              taxonomyId={product.taxonomy_id}
              onChange={(taxonomy_id) => updateProduct({ taxonomy_id })}
              taxonomies={taxonomies}
            />
            <TagSelector tags={product.tags} onChange={(tags) => updateProduct({ tags })} />
            <fieldset>
              <Toggle
                value={product.display_product_reviews}
                onChange={(newValue) => updateProduct({ display_product_reviews: newValue })}
              >
                Hiển thị xếp hạng 1-5 sao của sản phẩm cho khách hàng tiềm năng
              </Toggle>
              <Toggle value={product.is_adult} onChange={(newValue) => updateProduct({ is_adult: newValue })}>
                Sản phẩm này chứa nội dung chỉ dành cho{" "}
                <a href="/help/article/156-gumroad-and-adult-content" target="_blank" rel="noreferrer">
                  người lớn,
                </a>{" "}
                bao gồm cả bản xem trước
              </Toggle>
            </fieldset>
          </section>
        </form>
      </div>
    </Layout>
  );
};

const DiscoverEligibilityPromo = () => {
  const [show, setShow] = React.useState(false);

  useRunOnce(() => {
    if (localStorage.getItem("showDiscoverEligibilityPromo") !== "false") setShow(true);
  });

  if (!show) return null;

  return (
    <Alert role="status">
      <div className="flex items-center gap-2">
        <img src={hands} alt="" className="size-12" />
        <div className="flex flex-1 flex-col gap-2">
          <div>
            Để xuất hiện trên Gumroad Discover, hãy đảm bảo đáp ứng tất cả các{" "}
            <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
              tiêu chí đủ điều kiện
            </a>
            , bao gồm việc thực hiện ít nhất một giao dịch thành công và hoàn thành quy trình Đánh giá Rủi ro được giải thích chi tiết{" "}
            <a href="/help/article/13-getting-paid" target="_blank" rel="noreferrer">
              tại đây
            </a>
            .
          </div>
          <button
            className="w-max cursor-pointer underline all-unset"
            onClick={() => {
              localStorage.setItem("showDiscoverEligibilityPromo", "false");
              setShow(false);
            }}
          >
            Đóng
          </button>
        </div>
      </div>
    </Alert>
  );
};
