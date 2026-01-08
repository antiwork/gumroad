import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";

export const CreateVariantCategory = () => (
  <ApiEndpoint
    method="post"
    path="/products/:product_id/variant_categories"
    description="Create a new variant category on a product."
  >
    <ApiParameters>
      <ApiParameter name="variant_category" />
      <ApiParameter name="title" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "title=colors" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "variant_category": {
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "title": "colors"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetVariantCategory = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/variant_categories/:id"
    description="Retrieve the details of a variant category of a product."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories/mN7CdHiwHaR9FlxKvF-n-g== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "variant_category": {
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "title": "colors"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const UpdateVariantCategory = () => (
  <ApiEndpoint
    method="put"
    path="/products/:product_id/variant_categories/:id"
    description="Edit a variant category of an existing product."
  >
    <ApiParameters>
      <ApiParameter name="variant_category" />
      <ApiParameter name="title" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories/mN7CdHiwHaR9FlxKvF-n-g== \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "title=sizes" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "variant_category": {
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "title": "colors"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteVariantCategory = () => (
  <ApiEndpoint
    method="delete"
    path="/products/:product_id/variant_categories/:id"
    description="Permanently delete a variant category of a product."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories/mN7CdHiwHaR9FlxKvF-n-g== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The variant_category has been deleted successfully."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetVariantCategories = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/variant_categories"
    description="Retrieve all of the existing variant categories of a product."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "variant_categories": [{
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "title": "colors"
  }, {...}, {...}]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const CreateVariant = () => (
  <ApiEndpoint
    method="post"
    path="/products/:product_id/variant_categories/:variant_category_id/variants"
    description="Create a new variant of a product."
  >
    <ApiParameters>
      <ApiParameter name="variant" />
      <ApiParameter name="name" />
      <ApiParameter name="price_difference_cents" />
      <ApiParameter name="max_purchase_count" description="(optional)" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories/mN7CdHiwHaR9FlxKvF-n-g==/variants \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "name=red" \\
  -d "price_difference_cents=250"`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "variant": {
    "id": "lSC1XVfr2TC3WoCGY7YrUg==",
    "max_purchase_count": null,
    "name": "red",
    "price_difference_cents": 100
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetVariant = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/variant_categories/:variant_category_id/variants/:id"
    description="Retrieve the details of a variant of a product."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories/mN7CdHiwHaR9FlxKvF-n-g==/variants/kuaXCPHTmRuoK13rNGVbxg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "variant": {
    "id": "lSC1XVfr2TC3WoCGY7YrUg==",
    "max_purchase_count": null,
    "name": "red",
    "price_difference_cents": 100
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const UpdateVariant = () => (
  <ApiEndpoint
    method="put"
    path="/products/:product_id/variant_categories/:variant_category_id/variants/:id"
    description="Edit a variant of an existing product."
  >
    <ApiParameters>
      <ApiParameter name="variant" />
      <ApiParameter name="name" />
      <ApiParameter name="price_difference_cents" />
      <ApiParameter name="max_purchase_count" description="(optional)" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories/mN7CdHiwHaR9FlxKvF-n-g==/variants/kuaXCPHTmRuoK13rNGVbxg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "price_difference_cents=150" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "variant": {
    "id": "lSC1XVfr2TC3WoCGY7YrUg==",
    "max_purchase_count": null,
    "name": "red",
    "price_difference_cents": 100
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteVariant = () => (
  <ApiEndpoint
    method="delete"
    path="/products/:product_id/variant_categories/:variant_category_id/variants/:id"
    description="Permanently delete a variant of a product."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories/mN7CdHiwHaR9FlxKvF-n-g==/variants/kuaXCPHTmRuoK13rNGVbxg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The variant has been deleted successfully."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetVariants = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/variant_categories/:variant_category_id/variants"
    description="Retrieve all of the existing variants in a variant category."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/variant_categories/mN7CdHiwHaR9FlxKvF-n-g==/variants \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "variants": [{
    "id": "lSC1XVfr2TC3WoCGY7YrUg==",
    "max_purchase_count": null,
    "name": "red",
    "price_difference_cents": 100
  }, {...}, {...}]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
