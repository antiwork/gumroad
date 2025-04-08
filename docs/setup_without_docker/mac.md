### Why?

Docker may lead to hogging of memory and resources, especially on older Macs. Direct installation of the required services helps to prevent that.

### Required services

The below instructions will set up all services with the latest versions of the brew formulae. While this should usually work, you may run into issues due to a specific version not matching the docker version. In that case, you will have to manually install the respective version of that service.

For the versions required to match the docker setup, checkout `docker/docker-compose-local.yml`.

- MySQL
- Redis
- MongoDB
- Elasticsearch
- Nginx

#### MySQL

```
brew install mysql percona-toolkit
brew link --force mysql

# to use Homebrew's `openssl`:
brew install openssl
bundle config --global build.mysql2 --with-opt-dir="$(brew --prefix openssl)"

# to set root password (use password="password"):
$(brew —-prefix mysql)/bin/mysqladmin -u root password <NEWPASSWORD>
```

#### Redis

1. Install with Homebrew

   ```
   brew install redis
   ```

2. To have launchd start redis now and restart at login:
   ```
   brew services start redis
   ```
3. Test if Redis server is running.

   ```
   redis-cli ping
   ```

   If it replies “PONG”, then it’s good to go!

#### MongoDB

Search for the available versions using `brew search mongo` and install the appropriate one.

For example, to install version 3.6

```
brew install mongodb/brew/mongodb-community@3.6
```

#### Elasticsearch

1.  ```sh
    brew tap elastic/tap
    brew install elastic/tap/elasticsearch-full
    ```
2.  Add the following to your `.bashrc`/`.zshrc` file

    ```
    export ES_JAVA_OPTS=-Xms512m -Xmx512m
    export discovery.type=single-node
    ```

#### Nginx

1. ```
   brew install nginx
   ```

2. `cd` into the main repository directory:

   ```
   cd /path/to/gumroad/web
   ```

3. Copy the `docs/setup_without_docker/gumroad_dev.conf` file from this repository into Nginx's `servers/` directory.
   ```
   sudo cp ${PWD}/docs/setup_without_docker/gumroad_dev.conf /usr/local/etc/nginx/servers/
   ```
4. Symlink the SSL certificate and private key configured for `gumroad.dev` and `*.gumroad.dev` domains to `/etc/ssl/certs` directory.

   ```
   sudo mkdir -p /etc/ssl/certs
   sudo ln -s ${PWD}/docker/local-nginx/certs/gumroad_dev.crt /etc/ssl/certs/gumroad_dev.crt
   sudo ln -s ${PWD}/docker/local-nginx/certs/gumroad_dev.key /etc/ssl/certs/gumroad_dev.key
   ```

5. Check if the config is OK with the following command -

   ```
   sudo nginx -t
   ```

6. Restart Nginx

   ```
   brew services restart nginx
   ```

Now follow the rest of the [README.md](https://github.com/antiwork/gumroad/blob/main/README.md) for the installation process. Once done open https://gumroad.dev after running the `foreman` command and it should point to your Gumroad server!
