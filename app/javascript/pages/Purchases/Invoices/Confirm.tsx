import { Form, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Card, CardContent } from "$app/components/ui/Card";

const PurchasesInvoiceConfirmationPage = () => {
  const { url } = usePage();

  return (
    <div>
      <Card asChild>
        <main className="single-page-form horizontal-form mx-auto my-4 h-min max-w-md [&>*]:flex-col [&>*]:items-stretch">
          <CardContent asChild>
            <header className="text-center">
              <h2 className="grow">Generate invoice</h2>
            </header>
          </CardContent>
          <CardContent asChild>
            <Form action={url} method="POST" options={{ preserveScroll: true }} className="flex flex-col gap-4">
              {({ processing }) => (
                <>
                  <input type="text" name="email" placeholder="Email address" className="grow" />
                  <Button type="submit" color="accent" disabled={processing}>
                    Confirm email
                  </Button>
                </>
              )}
            </Form>
          </CardContent>
        </main>
      </Card>
    </div>
  );
};

PurchasesInvoiceConfirmationPage.publicLayout = true;
export default PurchasesInvoiceConfirmationPage;
