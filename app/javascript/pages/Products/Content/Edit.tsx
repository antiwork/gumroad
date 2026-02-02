import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Seller } from "$app/components/Product";

import { BaseProductEditPageProps, ExistingFileEntry, FileEntry } from "../Shared/types";
import { EditLayout } from "../Shared/EditLayout";

// We'll import the ContentTab component which uses the ProductEdit context
import { ProductEditContext } from "$app/components/ProductEdit/state";
import { ContentTab } from "$app/components/ProductEdit/ContentTab";

type ContentPageProps = BaseProductEditPageProps & {
  product: {
    name: string;
    variants: Array<{
      id: string;
      name: string;
      integrations: Record<string, boolean>;
      rich_content: any[];
      duration_in_minutes?: number | null;
    }>;
    rich_content: any[];
    files: FileEntry[];
    has_same_rich_content_for_all_variants: boolean;
    native_type: string;
    is_published?: boolean;
  };
  seller: Seller;
  existing_files: ExistingFileEntry[];
  s3_url: string;
  aws_key: string;
  successful_sales_count: number;
};

type ContentFormData = {
  variants: Array<{
    id: string;
    name: string;
    integrations: Record<string, boolean>;
    rich_content: any[];
    duration_in_minutes?: number | null;
  }>;
  rich_content: any[];
  files: FileEntry[];
  has_same_rich_content_for_all_variants: boolean;
};

export default function ProductsContentEdit() {
  const page = usePage();
  const props = cast<ContentPageProps>(page.props);
  const {
    product: initialProduct,
    id,
    unique_permalink,
    seller,
    existing_files,
    s3_url,
    aws_key,
  } = props;

  const [product, setProduct] = React.useState({
    ...initialProduct,
    variants: initialProduct.variants.map((v) => ({ ...v, rich_content: v.rich_content || [] })),
    rich_content: initialProduct.rich_content || [],
    files: initialProduct.files || [],
  });

  const [existingFiles, setExistingFiles] = React.useState(existing_files);

  const form = useForm<ContentFormData>({
    variants: product.variants,
    rich_content: product.rich_content,
    files: product.files,
    has_same_rich_content_for_all_variants: product.has_same_rich_content_for_all_variants,
  });

  // Sync form data with product state changes
  React.useEffect(() => {
    form.setData({
      variants: product.variants,
      rich_content: product.rich_content,
      files: product.files,
      has_same_rich_content_for_all_variants: product.has_same_rich_content_for_all_variants,
    });
  }, [product]);

  const transformContentData = () => ({
    variants: form.data.variants.map((variant) => ({
      id: variant.id,
      integrations: variant.integrations,
      rich_content: variant.rich_content,
    })),
    rich_content: form.data.rich_content,
    files: form.data.files.filter((file) => file.status.type !== "removed"),
    has_same_rich_content_for_all_variants: form.data.has_same_rich_content_for_all_variants,
  });

  const submitForm = (additionalData: Record<string, unknown> = {}, options?: { onSuccess?: () => void }) => {
    if (form.processing) return;
    form.transform(() => ({ ...transformContentData(), ...additionalData }));
    form.put(Routes.product_content_path(id), {
      preserveScroll: true,
      ...(options?.onSuccess && { onSuccess: options.onSuccess }),
    });
  };

  const handleSave = async () => {
    submitForm();
  };

  // Update product helper
  const updateProduct = (updater: any) => {
    setProduct((prev) => {
      const next = { ...prev };
      if (typeof updater === "function") {
        updater(next);
      } else {
        Object.assign(next, updater);
      }
      return next;
    });
  };

  // Build preview product from form data
  const previewProduct = {
    ...product,
    name: initialProduct.name,
  } as any;

  // Create a filesById map for the context
  const filesById = React.useMemo(() => {
    const map = new Map();
    product.files.forEach((file) => map.set(file.id, file));
    return map;
  }, [product.files]);

  // Create the context value for ContentTab
  const contextValue = React.useMemo(
    () => ({
      id,
      product: product as any,
      updateProduct,
      uniquePermalink: unique_permalink,
      seller,
      existingFiles,
      setExistingFiles,
      awsKey: aws_key,
      s3Url: s3_url,
      save: handleSave,
      saving: form.processing,
      filesById,
      // These are dummy values that ContentTab doesn't actually use for its core functionality
      thumbnail: null,
      refundPolicies: [],
      currencyType: "usd" as any,
      setCurrencyType: () => {},
      isListedOnDiscover: false,
      isPhysical: false,
      profileSections: [],
      taxonomies: [],
      earliestMembershipPriceChangeDate: new Date(),
      customDomainVerificationStatus: null,
      salesCountForInventory: 0,
      successfulSalesCount: 0,
      ratings: {} as any,
      availableCountries: [],
      googleClientId: "",
      googleCalendarEnabled: false,
      seller_refund_policy_enabled: false,
      seller_refund_policy: { title: "", fine_print: "" },
      cancellationDiscountsEnabled: false,
      contentUpdates: null,
      setContentUpdates: () => {},
      aiGenerated: false,
    }),
    [id, product, unique_permalink, seller, existingFiles, aws_key, s3_url, form.processing, filesById],
  );

  return (
    <EditLayout
      productId={id}
      uniquePermalink={unique_permalink}
      currentTab="content"
      onSave={handleSave}
      isSaving={form.processing}
      product={previewProduct}
    >
      <ProductEditContext.Provider value={contextValue}>
        <ContentTab />
      </ProductEditContext.Provider>
    </EditLayout>
  );
}


