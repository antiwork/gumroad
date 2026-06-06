import React from "react";

import { ApiResource } from "$app/components/ApiDocumentation/ApiResource";
import { Authentication } from "$app/components/ApiDocumentation/Authentication";
import { CommandLine } from "$app/components/ApiDocumentation/CommandLine";
import { CreateCover, DeleteCover } from "$app/components/ApiDocumentation/Endpoints/Covers";
import {
  CreateCustomField,
  DeleteCustomField,
  GetCustomFields,
  UpdateCustomField,
} from "$app/components/ApiDocumentation/Endpoints/CustomFields";
import { GetEarnings } from "$app/components/ApiDocumentation/Endpoints/Earnings";
import {
  AbortFile,
  AttachFile,
  CompleteFile,
  FilesOverview,
  PresignFile,
} from "$app/components/ApiDocumentation/Endpoints/Files";
import {
  DecrementUsesCount,
  DisableLicense,
  EnableLicense,
  RotateLicense,
  VerifyLicense,
} from "$app/components/ApiDocumentation/Endpoints/Licenses";
import {
  CreateOfferCode,
  DeleteOfferCode,
  GetOfferCode,
  GetOfferCodes,
  UpdateOfferCode,
} from "$app/components/ApiDocumentation/Endpoints/OfferCodes";
import { GetPayout, GetPayouts, GetUpcomingPayouts } from "$app/components/ApiDocumentation/Endpoints/Payouts";
import {
  CreateProduct,
  DeleteProduct,
  DisableProduct,
  EnableProduct,
  GetCategories,
  GetProduct,
  GetProducts,
  UpdateProduct,
} from "$app/components/ApiDocumentation/Endpoints/Products";
import { GetPublicProductPage } from "$app/components/ApiDocumentation/Endpoints/PublicProductPage";
import { GetRefundPolicy, UpdateRefundPolicy } from "$app/components/ApiDocumentation/Endpoints/RefundPolicy";
import {
  CreateResourceSubscription,
  DeleteResourceSubscription,
  GetResourceSubscriptions,
} from "$app/components/ApiDocumentation/Endpoints/ResourceSubscriptions";
import {
  MarkSaleAsShipped,
  RefundSale,
  ResendReceipt,
  GetSale,
  GetSales,
} from "$app/components/ApiDocumentation/Endpoints/Sales";
import { GetSubscribers, GetSubscriber } from "$app/components/ApiDocumentation/Endpoints/Subscribers";
import { GetTaxForms, DownloadTaxForm } from "$app/components/ApiDocumentation/Endpoints/TaxForms";
import { CreateThumbnail, DeleteThumbnail } from "$app/components/ApiDocumentation/Endpoints/Thumbnails";
import { GetUser } from "$app/components/ApiDocumentation/Endpoints/User";
import {
  CreateVariant,
  CreateVariantCategory,
  DeleteVariant,
  DeleteVariantCategory,
  GetVariant,
  GetVariantCategories,
  GetVariantCategory,
  GetVariants,
  UpdateVariant,
  UpdateVariantCategory,
} from "$app/components/ApiDocumentation/Endpoints/Variants";
import { Errors } from "$app/components/ApiDocumentation/Errors";
import { Introduction } from "$app/components/ApiDocumentation/Introduction";
import { Navigation } from "$app/components/ApiDocumentation/Navigation";
import { Resources } from "$app/components/ApiDocumentation/Resources";
import { Scopes } from "$app/components/ApiDocumentation/Scopes";
import { Layout } from "$app/components/Developer/Layout";
import { Card, CardContent } from "$app/components/ui/Card";

export default function Api() {
  React.useEffect(() => {
    const scrollToHash = () => {
      const id = decodeURIComponent(window.location.hash.slice(1));
      const target = id ? document.getElementById(id) : null;
      target?.scrollIntoView();
    };
    const frame = requestAnimationFrame(scrollToHash);
    window.addEventListener("hashchange", scrollToHash);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("hashchange", scrollToHash);
    };
  }, []);

  return (
    <Layout currentPage="api">
      <main className="p-4 md:p-8">
        <div>
          <div className="grid grid-cols-1 items-start gap-x-16 gap-y-8 lg:grid-cols-[var(--grid-cols-sidebar)]">
            <Navigation />
            <article className="grid gap-8">
              <CommandLine />
              <Introduction />
              <Authentication />
              <Scopes />
              <Resources />
              <Errors />
              <Card id="api-methods">
                <CardContent>
                  <h2 className="grow">API Methods</h2>
                </CardContent>
                <CardContent>
                  <p className="grow">
                    Gumroad's OAuth 2.0 API lets you see information about your products, as well as you can add, edit,
                    and delete offer codes, variants, and custom fields. Finally, you can see a user's public
                    information and subscribe to be notified of their sales.
                  </p>
                </CardContent>
              </Card>

              <ApiResource name="Products" id="products">
                <GetProducts />
                <GetProduct />
                <CreateProduct />
                <UpdateProduct />
                <DeleteProduct />
                <EnableProduct />
                <DisableProduct />
              </ApiResource>

              <ApiResource name="Public product page" id="public-product-page">
                <GetPublicProductPage />
              </ApiResource>

              <ApiResource name="Categories" id="categories">
                <GetCategories />
              </ApiResource>

              <ApiResource name="Files" id="files">
                <FilesOverview />
                <PresignFile />
                <CompleteFile />
                <AbortFile />
                <AttachFile />
              </ApiResource>

              <ApiResource name="Covers" id="covers">
                <CreateCover />
                <DeleteCover />
              </ApiResource>

              <ApiResource name="Thumbnails" id="thumbnails">
                <CreateThumbnail />
                <DeleteThumbnail />
              </ApiResource>

              <ApiResource name="Variant categories" id="variant-categories">
                <CreateVariantCategory />
                <GetVariantCategory />
                <UpdateVariantCategory />
                <DeleteVariantCategory />
                <GetVariantCategories />
                <CreateVariant />
                <GetVariant />
                <UpdateVariant />
                <DeleteVariant />
                <GetVariants />
              </ApiResource>

              <ApiResource name="Offer codes" id="offer-codes">
                <GetOfferCodes />
                <GetOfferCode />
                <CreateOfferCode />
                <UpdateOfferCode />
                <DeleteOfferCode />
              </ApiResource>

              <ApiResource name="Custom fields" id="custom-fields">
                <GetCustomFields />
                <CreateCustomField />
                <UpdateCustomField />
                <DeleteCustomField />
              </ApiResource>

              <ApiResource name="User" id="user">
                <GetUser />
              </ApiResource>

              <ApiResource name="Refund policy" id="refund-policy">
                <GetRefundPolicy />
                <UpdateRefundPolicy />
              </ApiResource>

              <ApiResource name="Resource subscriptions" id="resource-subscriptions">
                <CreateResourceSubscription />
                <GetResourceSubscriptions />
                <DeleteResourceSubscription />
              </ApiResource>

              <ApiResource name="Sales" id="sales">
                <GetSales />
                <GetSale />
                <MarkSaleAsShipped />
                <RefundSale />
                <ResendReceipt />
              </ApiResource>

              <ApiResource name="Subscribers" id="subscribers">
                <GetSubscribers />
                <GetSubscriber />
              </ApiResource>

              <ApiResource name="Licenses" id="licenses">
                <VerifyLicense />
                <EnableLicense />
                <DisableLicense />
                <DecrementUsesCount />
                <RotateLicense />
              </ApiResource>

              <ApiResource name="Payouts" id="payouts">
                <GetPayouts />
                <GetPayout />
                <GetUpcomingPayouts />
              </ApiResource>

              <ApiResource name="Tax forms" id="tax-forms">
                <GetTaxForms />
                <DownloadTaxForm />
              </ApiResource>

              <ApiResource name="Earnings" id="earnings">
                <GetEarnings />
              </ApiResource>
            </article>
          </div>
        </div>
      </main>
    </Layout>
  );
}
