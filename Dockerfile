FROM alpine:3.8 as base
LABEL maintainer="Denys Zhdanov <denis.zhdanov@gmail.com>"

RUN true \
 && apk add --no-cache \
      cairo \
      collectd \
      collectd-disk \
      collectd-nginx \
      findutils \
      librrd \
      logrotate \
      memcached \
      nginx \
      nodejs \
      npm \
      py3-pyldap \
      redis \
      runit \
      sqlite \
      expect \
      dcron \
 && rm -rf \
      /etc/nginx/conf.d/default.conf \
 && mkdir -p \
      /var/log/carbon \
      /var/log/graphite

FROM base as build
LABEL maintainer="Denys Zhdanov <denis.zhdanov@gmail.com>"

RUN true \
 && apk add --update \
      alpine-sdk \
      git \
      libffi-dev \
      pkgconfig \
      py3-cairo \
      py3-pip \
      py3-pyldap \
      py3-virtualenv \
      py-rrd \
      python3-dev \
      rrdtool-dev \
      wget \
 && virtualenv /opt/graphite \
 && . /opt/graphite/bin/activate \
 && pip3 install \
      django==1.11.15 \
      django-statsd-mozilla \
      fadvise \
      gunicorn \
      msgpack-python \
      redis \
      rrdtool

ARG version=1.1.5

# install whisper
ARG whisper_version=${version}
ARG whisper_repo=https://github.com/graphite-project/whisper.git
RUN git clone -b ${whisper_version} --depth 1 ${whisper_repo} /usr/local/src/whisper \
 && cd /usr/local/src/whisper \
 && . /opt/graphite/bin/activate \
 && python3 ./setup.py install

# install carbon
ARG carbon_version=${version}
ARG carbon_repo=https://github.com/graphite-project/carbon.git
RUN . /opt/graphite/bin/activate \
 && git clone -b ${carbon_version} --depth 1 ${carbon_repo} /usr/local/src/carbon \
 && cd /usr/local/src/carbon \
 && pip3 install -r requirements.txt \
 && python3 ./setup.py install

# install graphite
ARG graphite_version=${version}
ARG graphite_repo=https://github.com/graphite-project/graphite-web.git
RUN . /opt/graphite/bin/activate \
 && git clone -b ${graphite_version} --depth 1 ${graphite_repo} /usr/local/src/graphite-web \
 && cd /usr/local/src/graphite-web \
 && pip3 install -r requirements.txt \
 && python3 ./setup.py install

# install statsd (as we have to use this ugly way)
ARG statsd_version=8d5363cb109cc6363661a1d5813e0b96787c4411
ARG statsd_repo=https://github.com/etsy/statsd.git
RUN git init /opt/statsd \
 && git -C /opt/statsd remote add origin "${statsd_repo}" \
 && git -C /opt/statsd fetch origin "${statsd_version}" \
 && git -C /opt/statsd checkout "${statsd_version}" \
 && cd /opt/statsd \
 && npm install

COPY conf/opt/graphite/conf/                             /opt/defaultconf/graphite/
COPY conf/opt/graphite/webapp/graphite/local_settings.py /opt/defaultconf/graphite/local_settings.py

# config graphite
COPY conf/opt/graphite/conf/*.conf /opt/graphite/conf/
COPY conf/opt/graphite/webapp/graphite/local_settings.py /opt/graphite/webapp/graphite/local_settings.py
WORKDIR /opt/graphite/webapp
RUN mkdir -p /var/log/graphite/ \
  && PYTHONPATH=/opt/graphite/webapp /opt/graphite/bin/django-admin.py collectstatic --noinput --settings=graphite.settings

# config statsd
COPY conf/opt/statsd/config/ /opt/defaultconf/statsd/config/

# Grafana installation
ENV GRAFANA_VERSION=5.4.0

# I can't get the wizzy stuff to work with their node js
# This was painful, it was install 8.10.0 without installing npm. From here https://deb.nodesource.com/node_6.x/dists/bionic/main/binary-amd64/Packages
# I found the version number.  
RUN	curl -sL https://deb.nodesource.com/setup_6.x | bash - \
    && apt-get install -y nodejs=6.14.1-1nodesource1 wget \
	&& npm install -g wizzy

RUN     mkdir -p /src/grafana \
        && mkdir -p /opt/grafana \
        && wget https://s3-us-west-2.amazonaws.com/grafana-releases/release/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz -O /src/grafana.tar.gz \
        && tar -xzf /src/grafana.tar.gz -C /opt/grafana --strip-components=1 \
        && rm /src/grafana.tar.gz

# Configure Grafana
ADD     ./grafana/custom.ini /opt/grafana/conf/custom.ini

RUN	cd /src \
    && wizzy init \
	&& extract() { cat /opt/grafana/conf/custom.ini | grep $1 | awk '{print $NF}'; } \
	&& wizzy set grafana url $(extract ";protocol")://$(extract ";domain"):$(extract ";http_port")	\		
	&& wizzy set grafana username $(extract ";admin_user")	\
	&& wizzy set grafana password $(extract ";admin_password")
	
# Add the default dashboards
RUN 	mkdir /src/datasources \
        && mkdir /src/dashboards
ADD	    ./grafana/datasources/* /src/datasources
ADD     ./grafana/dashboards/* /src/dashboards/
ADD     ./grafana/export-datasources-and-dashboards.sh /src/

# Run file was not executable
RUN chmod +x /etc/service/grafana/run

# End Grafana installation



FROM base as production
LABEL maintainer="Denys Zhdanov <denis.zhdanov@gmail.com>"

ENV STATSD_INTERFACE udp

COPY conf /

# copy /opt from build image
COPY --from=build /opt /opt
# copy Grafana from build image
COPY --from=build /src /src

# defaults
EXPOSE 80 2003-2004 2013-2014 2023-2024 8080 8125 8125/udp 8126
VOLUME ["/opt/graphite/conf", "/opt/graphite/storage", "/opt/graphite/webapp/graphite/functions/custom", "/etc/nginx", "/opt/statsd/config", "/etc/logrotate.d", "/var/log", "/var/lib/redis"]

STOPSIGNAL SIGHUP

ENTRYPOINT ["/entrypoint"]
