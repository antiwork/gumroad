import { Form, usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Card, CardContent } from "$app/components/ui/Card";
import { Input } from "$app/components/ui/Input";

const PurchasesInvoiceConfirmationPage = () => {
  const { url } = usePage();

  return (
    <div className="flex flex-1 flex-col justify-between p-4">
      <Card asChild>
        <main className="mx-auto h-min w-full max-w-md">
          <CardContent asChild>
            <header className="text-center">
              <h2>Generate invoice</h2>
            </header>
          </CardContent>
          <CardContent asChild>
            <Form action={url} method="POST" options={{ preserveScroll: true }} className="flex flex-col gap-4">
              {({ processing }) => (
                <>
                  <Input type="text" name="email" placeholder="Email address" className="grow" />
                  <Button type="submit" color="accent" disabled={processing}>
                    Confirm email
                  </Button>
                </>
              )}
            </Form>
          </CardContent>
        </main>
      </Card>
      <PoweredByFooter />
    </div>
  );
};

PurchasesInvoiceConfirmationPage.publicLayout = true;
export default PurchasesInvoiceConfirmationPage;
