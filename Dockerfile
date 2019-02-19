# First we build our static assets using the Node image as a build-step
FROM node:11-alpine as static-build

WORKDIR /usr/src/app

COPY package.json ./
COPY yarn.lock ./

RUN yarn install \
    && yarn cache clean

COPY . .

RUN yarn run build

# Now create our image which will run the Wordpress instance
FROM php:7.1-apache

# install the PHP extensions we need
RUN set -ex; \
    \
    savedAptMark="$(apt-mark showmanual)"; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    libjpeg-dev \
    libpng-dev \
    ; \
    \
    docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr; \
    docker-php-ext-install gd mysqli opcache zip; \
    \
    # reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
    | awk '/=>/ { print $3 }' \
    | sort -u \
    | xargs -r dpkg-query -S \
    | cut -d: -f1 \
    | sort -u \
    | xargs -rt apt-mark manual; \
    \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=2'; \
    echo 'opcache.fast_shutdown=1'; \
    echo 'opcache.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

RUN { \
    echo 'mysqli.max_persistent=0'; \
    } > /usr/local/etc/php/conf.d/mysqli.ini

RUN a2enmod rewrite expires

ENV APACHE_DOCUMENT_ROOT /var/www/html/web

RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf
RUN sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

# Install composer https://getcomposer.org/download/

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

COPY composer.json ./
COPY composer.lock ./

RUN composer install --prefer-dist --no-scripts --no-autoloader --no-progress --no-suggest \
    && composer clear-cache

COPY ./ ./
COPY --from=static-build /usr/src/app/web/app/themes/default-theme/dist /var/www/html/web/app/themes/default-theme/dist

RUN mv web/ht.access web/.htaccess
RUN chown -R www-data:www-data ./

RUN composer dump-autoload --no-scripts --optimize
