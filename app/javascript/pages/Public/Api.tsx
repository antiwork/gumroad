import React from "react";

import { ApiResource } from "$app/components/ApiDocumentation/ApiResource";
import { Authentication } from "$app/components/ApiDocumentation/Authentication";
import {
  GetCustomFields,
  CreateCustomField,
  UpdateCustomField,
  DeleteCustomField,
} from "$app/components/ApiDocumentation/Endpoints/CustomFields";
import {
  VerifyLicense,
  EnableLicense,
  DisableLicense,
  DecrementUsesCount,
  RotateLicense,
} from "$app/components/ApiDocumentation/Endpoints/Licenses";
import {
  GetOfferCodes,
  GetOfferCode,
  CreateOfferCode,
  UpdateOfferCode,
  DeleteOfferCode,
} from "$app/components/ApiDocumentation/Endpoints/OfferCodes";
import { GetPayouts, GetPayout } from "$app/components/ApiDocumentation/Endpoints/Payouts";
import {
  GetProducts,
  GetProduct,
  DeleteProduct,
  EnableProduct,
  DisableProduct,
} from "$app/components/ApiDocumentation/Endpoints/Products";
import {
  CreateResourceSubscription,
  GetResourceSubscriptions,
  DeleteResourceSubscription,
} from "$app/components/ApiDocumentation/Endpoints/ResourceSubscriptions";
import {
  GetSales,
  GetSale,
  MarkSaleAsShipped,
  RefundSale,
  ResendReceipt,
} from "$app/components/ApiDocumentation/Endpoints/Sales";
import { GetSubscribers, GetSubscriber } from "$app/components/ApiDocumentation/Endpoints/Subscribers";
import { GetUser } from "$app/components/ApiDocumentation/Endpoints/User";
import {
  CreateVariantCategory,
  GetVariantCategory,
  UpdateVariantCategory,
  DeleteVariantCategory,
  GetVariantCategories,
  CreateVariant,
  GetVariant,
  UpdateVariant,
  DeleteVariant,
  GetVariants,
} from "$app/components/ApiDocumentation/Endpoints/Variants";
import { Errors } from "$app/components/ApiDocumentation/Errors";
import { Introduction } from "$app/components/ApiDocumentation/Introduction";
import { Navigation } from "$app/components/ApiDocumentation/Navigation";
import { Resources } from "$app/components/ApiDocumentation/Resources";
import { Scopes } from "$app/components/ApiDocumentation/Scopes";
import { Layout } from "$app/components/Developer/Layout";

export default function Api() {
  return (
    <Layout currentPage="api">
      <main className="p-4 md:p-8">
        <div>
          <div className="grid grid-cols-1 items-start gap-x-16 gap-y-8 lg:grid-cols-[var(--grid-cols-sidebar)]">
            <Navigation />
            <article className="grid gap-8">
              <Introduction />
              <Authentication />
              <Scopes />
              <Resources />
              <Errors />
              <div className="stack" id="api-methods">
                <div>
                  <h2>API Methods</h2>
                </div>
                <div>
                  <p>
                    Gumroad's OAuth 2.0 API lets you see information about your products, as well as you can add, edit,
                    and delete offer codes, variants, and custom fields. Finally, you can see a user's public
                    information and subscribe to be notified of their sales.
                  </p>
                </div>
              </div>

              <ApiResource name="Products" id="products">
                <GetProducts />
                <GetProduct />
                <DeleteProduct />
                <EnableProduct />
                <DisableProduct />
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
              </ApiResource>
            </article>
          </div>
        </div>
      </main>
    </Layout>
  );
}
