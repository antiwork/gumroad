## Steps for memory profiling

1. Download and run the docker instance

   ```bash
   docker pull gumroad/web:<env>-<revision>
   make local # In a seperate window
   docker run -it -e BUILD_JS=1 -e RAILS_LOG_LEVEL=error --shm-size=256m -p 3000:3000 --network web_default gumroad/web:<env>-<revision> /bin/bash
   ```

2. Run ngrok in local machine

   ```bash
   ngrok http 3000
   ```

3. Run puma in docker instance

   ```bash
   screen -S puma bash
   cd /app
   RAILS_ENV=<env> CUSTOM_DOMAIN=<ngrok domain> PUMA_WORKER_PROCESSES=<workers count> ./bin/memusg.sh ./docker/web/server.sh
   ```

4. Run Sidekiq in docker instance

   ```bash
   screen -S puma bash
   cd /app
   RAILS_ENV=<env> ./bin/memusg.sh ./docker/web/sidekiq_worker.sh
   ```

5. [Create products and make](#operations-in-application) purchases in Gumroad through ngrok URL

6. Connect to screen and read memory usage

   ```bash
   screen -x puma
   Press Ctrl+c and note the peak memory usage.
   ```

   ```bash
   screen -x sidekiq
   Press Ctrl+c and note the peak memory usage.
   ```

## Operations in application

Repeat the following steps for 5 different products

```
Step 1. Navigate to ngrok url
Step 2. Login using email ‘seller@gumroad.com’ and password ‘password’
Step 3. Landed to Home page of gumroad .
Step 4. Click products > Add Products
Step 5. Add Physical Product.
Step 6. Input Product Name as Sample Product
Step 7. In production, set $0 as price (test PayPal  payment doesn’t work in production) and set $10 as price if the environment staging.
Step 8. Click "Next"
Step 9. Click "Publish" and "Save Changes button".
Step 10. url is generated
Step 11. Copy the url of the product.
Step 12. Open a separate browser and paste the url.
Step 13. Product page is displayed
Step 14. Click "I want this product".
Step 15 . Input email. full name, Street, City, Zip Code, State, Country.
Step 16. Click PayPal if the test is in staging or "get now" if the test is in production.
Step 17. Input PayPal ID and Password sharang+merchant-facilitator@bigbinary.com / welcome123
Step 19. PayPal Payment is added from PayPal site and PayPal account is displayed in the gumroad page.
Step 20. Click “Pay” in staging. If it’s production, click “Get”.
Step 21. Confirm the transaction is successful and the receipt is generated and received over email.
Step 22. Navigate to ngrok url for bundle purchase
Step 23. Click products > Add Products
Step 24. Add 5 Products in different category
Step 25. In production, set $0 as price (test PayPal  payment doesn’t work in production) and set $10 as price if the environment is staging.
Step 26. Click Next
Step 27. Click "Publish" and "Save Changes button"
Step 28. URL is generated for each product.
Step 29. Navigate to profile page of the user in separate browser.
Step 30. Added products in chart
Step 31. Click "Pay"
Step 32. Input email. full name, Street, City, Zip Code, State, Country.
Step 33. Click PayPal if the test is in staging or "get now" if the test is in production.
Step 34. Input PayPal ID and Password sharang+merchant-facilitator@bigbinary.com / welcome123
Step 35. PayPal Payment is added from PayPal site and PayPal account is displayed in the gumroad page.
Step 36. Click “Pay” in staging. If it’s production, click “Get”.
Step 37. Confirm the transaction is successful and the receipt is generated and received over email.
```
